# ============================================================
#  ADO Repository Inventory Script
#  - Paginated project fetching via continuationToken
#  - Repo fetching via continuationToken (safe for 7k/10k+ repos)
#  - Last push date per repo (Pushes API, $top=1)
#  - Parallel push fetching when project has > 5k repos
#  - Activity status: Active / Stale / Inactive / Never Used
#  - Retry-After header respected with exponential backoff
#  - Safe throttle delays on every API call
#  - Skipped/failed project error log
# ============================================================

param (
    [string]$Org             = "",
    [string]$Pat             = "",
    [string]$OutputCsv       = "ado_repo_inventory_updated.csv",
    [string]$ErrorLog        = "ado_repo_inventory_errors.log",
    [int]$DelayMs             = 250,    # ms between every sequential API call
    [int]$MaxRetries          = 6,
    [int]$ParallelThreshold   = 5000,   # use parallel push fetching when project repo count exceeds this
    [int]$ThrottleLimit       = 4,      # parallel threads for push date fetching — keep low to avoid 429s
    [int]$BatchDelayMs        = 500     # ms to wait between each batch of parallel threads
)

# ── Auth ──────────────────────────────────────────────────────────────────────
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $auth" }

# ── Clean up previous run outputs ─────────────────────────────────────────────
if (Test-Path $OutputCsv) { Remove-Item $OutputCsv -Force }
if (Test-Path $ErrorLog)  { Remove-Item $ErrorLog  -Force }

$csvInitialized = $false

# ── Activity thresholds ───────────────────────────────────────────────────────
$activeThresholdDays   = 180   # < 6 months  = Active
$staleThresholdDays    = 365   # 6-12 months = Stale, > 12 months = Inactive

function Get-ActivityStatus {
    param ([string]$LastPushDate)

    if ($LastPushDate -eq "Never") { return "Never Used" }
    if ($LastPushDate -eq "Unknown") { return "Unknown" }

    try {
        $daysSince = (New-TimeSpan -Start ([datetime]$LastPushDate) -End (Get-Date)).Days
        if ($daysSince -lt $activeThresholdDays)  { return "Active" }
        if ($daysSince -lt $staleThresholdDays)   { return "Stale" }
        return "Inactive"
    }
    catch { return "Unknown" }
}

# ── Core API wrapper ──────────────────────────────────────────────────────────
function Invoke-ADOApi {
    param (
        [string]$Url,
        [int]$MaxRetries = $script:MaxRetries
    )

    $retry = 0
    while ($retry -lt $MaxRetries) {
        try {
            $raw   = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction Stop -UseBasicParsing
            $body  = $raw.Content | ConvertFrom-Json

            $contToken = $null
            if ($raw.Headers.ContainsKey("x-ms-continuationtoken")) {
                $contToken = $raw.Headers["x-ms-continuationtoken"]
            }
            if (-not $contToken -and $body.PSObject.Properties["continuationToken"]) {
                $contToken = $body.continuationToken
            }

            return [PSCustomObject]@{ Body = $body; ContinuationToken = $contToken }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode }

            if ($statusCode -eq 429 -or $statusCode -eq 503) {
                $retryAfter = $null
                try { $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
                $wait = if ($retryAfter -and $retryAfter -gt 0) { $retryAfter } else { [math]::Min(120, [math]::Pow(2, $retry + 1)) }
                Write-Host "  [THROTTLED] HTTP $statusCode — waiting ${wait}s before retry $($retry+1)/$MaxRetries..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
                $retry++
            }
            else {
                Write-Warning "  [API ERROR] HTTP $statusCode — $Url"
                return $null
            }
        }
    }

    Write-Warning "  [MAX RETRIES] Giving up on: $Url"
    return $null
}

function Wait-PoliteDelay { Start-Sleep -Milliseconds $DelayMs }

function Write-CsvRow {
    param ([PSCustomObject]$Row)
    if (-not $script:csvInitialized) {
        $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8
        $script:csvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8 -Append
    }
}

function Write-ErrorLog {
    param ([string]$Message)
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $script:ErrorLog -Value "[$timestamp] $Message"
    Write-Warning $Message
}

# ── Sequential push date fetch (used when project repo count <= ParallelThreshold) ──
function Get-LastPushDateSequential {
    param (
        [string]$OrgName,
        [string]$ProjectName,
        [string]$RepoId
    )

    $url = "https://dev.azure.com/$OrgName/$([Uri]::EscapeDataString($ProjectName))/_apis/git/repositories/$RepoId/pushes" +
           "?`$top=1&api-version=7.1-preview.2"

    Wait-PoliteDelay
    $result = Invoke-ADOApi -Url $url

    if (-not $result -or -not $result.Body) { return "Unknown" }

    $pushes = $result.Body.value
    if (-not $pushes -or @($pushes).Count -eq 0) { return "Never" }

    $rawDate = $pushes[0].date
    if ($rawDate) {
        try { return ([datetime]$rawDate).ToString("yyyy-MM-dd HH:mm:ss") } catch { return $rawDate }
    }
    return "Unknown"
}

# ── Parallel push date fetch (used when project repo count > ParallelThreshold) ──
# Repos are processed in batches of $Threads with a delay between each batch
# to stay within ADO rate limits (~200 requests/30s per token).
# Returns a synchronized hashtable: repoId -> lastPushDate string
function Get-PushDatesParallel {
    param (
        [object[]]$Repos,
        [string]$OrgName,
        [string]$ProjectName,
        [string]$AuthHeader,
        [int]$Threads,
        [int]$Retries,
        [int]$BatchDelayMs
    )

    $results = [hashtable]::Synchronized(@{})

    $sb = {
        param($repo, $orgName, $projName, $authHeader, $maxRetries, $results)

        $hdrs  = @{ Authorization = $authHeader }
        $url   = "https://dev.azure.com/$orgName/$([Uri]::EscapeDataString($projName))/_apis/git/repositories/$($repo.id)/pushes" +
                 "?`$top=1&api-version=7.1-preview.2"
        $retry = 0
        $date  = "Unknown"

        while ($retry -lt $maxRetries) {
            try {
                $raw    = Invoke-WebRequest -Uri $url -Headers $hdrs -Method Get -ErrorAction Stop -UseBasicParsing
                $body   = $raw.Content | ConvertFrom-Json
                $pushes = $body.value
                $date   = if (-not $pushes -or @($pushes).Count -eq 0) {
                    "Never"
                } else {
                    $d = $pushes[0].date
                    if ($d) { try { ([datetime]$d).ToString("yyyy-MM-dd HH:mm:ss") } catch { $d } } else { "Unknown" }
                }
                break
            }
            catch {
                $sc = $null
                if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode }
                if ($sc -eq 429 -or $sc -eq 503) {
                    $ra = $null
                    try { $ra = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}
                    $wait   = if ($ra -and $ra -gt 0) { $ra } else { [math]::Min(120, [math]::Pow(2, $retry + 1)) }
                    $jitter = Get-Random -Minimum 0 -Maximum ([int]($wait * 0.2) + 1)
                    Start-Sleep -Seconds ($wait + $jitter)
                    $retry++
                }
                else { break }
            }
        }
        $results[$repo.id] = $date
    }

    # Process repos in batches of $Threads with a delay between each batch
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
    $pool.Open()

    $batches = [math]::Ceiling($Repos.Count / $Threads)
    for ($b = 0; $b -lt $batches; $b++) {
        $start     = $b * $Threads
        $end       = [math]::Min($start + $Threads - 1, $Repos.Count - 1)
        $batchRepos = $Repos[$start..$end]

        $jobs = foreach ($repo in $batchRepos) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            $ps.AddScript($sb)            | Out-Null
            $ps.AddArgument($repo)        | Out-Null
            $ps.AddArgument($OrgName)     | Out-Null
            $ps.AddArgument($ProjectName) | Out-Null
            $ps.AddArgument($AuthHeader)  | Out-Null
            $ps.AddArgument($Retries)     | Out-Null
            $ps.AddArgument($results)     | Out-Null
            [PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
        }

        # Wait for this batch to complete before starting next
        foreach ($job in $jobs) {
            $job.PS.EndInvoke($job.Handle) | Out-Null
            $job.PS.Dispose()
        }

        # Delay between batches to avoid sustained 429s
        if ($b -lt ($batches - 1)) {
            Start-Sleep -Milliseconds $BatchDelayMs
        }
    }

    $pool.Close()
    $pool.Dispose()

    return $results
}

# =============================================================================
#  STEP 1 — Fetch all projects in the organization, handling pagination
# =============================================================================
Write-Host "`nFetching projects..." -ForegroundColor Cyan

$allProjects       = [System.Collections.Generic.List[object]]::new()
$continuationToken = $null

do {
    $projUrl = "https://dev.azure.com/$Org/_apis/projects?`$top=100&api-version=7.1-preview.4"
    if ($continuationToken) { $projUrl += "&continuationToken=$continuationToken" }

    Wait-PoliteDelay
    $result = Invoke-ADOApi -Url $projUrl

    if ($result -and $result.Body.value) {
        $allProjects.AddRange($result.Body.value)
        Write-Host "  Fetched $($allProjects.Count) projects so far..."
    } else {
        Write-ErrorLog "Failed to fetch project page (continuationToken=$continuationToken)"
        break
    }
    $continuationToken = $result.ContinuationToken
} while ($continuationToken)

Write-Host "Total projects found: $($allProjects.Count)" -ForegroundColor Green

# =============================================================================
#  STEP 2 — For each project fetch repos, then fetch last push date per repo
#
#  Repo pagination  : continuationToken-based (reliable, no $skip loop issues)
#  Push date fetch  : sequential when repos <= 5k, parallel when repos > 5k
#  Activity status  : Active < 6 months, Stale 6-12 months,
#                     Inactive > 12 months, Never Used = never pushed
# =============================================================================
$totalRepos   = 0
$totalSkipped = 0
$projIndex    = 0

foreach ($proj in $allProjects) {
    $projIndex++
    $projName  = $proj.name
    $projRepos = 0
    $pageNum   = 0
    $projFailed = $false
    Write-Host "`n[$projIndex/$($allProjects.Count)] $projName" -ForegroundColor Cyan

    # ── Collect all repos for this project via continuationToken ─────────────
    $allRepos      = [System.Collections.Generic.List[object]]::new()
    $repoContToken = $null

    do {
        $pageNum++
        $repoUrl = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))/_apis/git/repositories?api-version=7.1-preview.1"
        if ($repoContToken) { $repoUrl += "&continuationToken=$repoContToken" }

        Wait-PoliteDelay
        $result = Invoke-ADOApi -Url $repoUrl

        if (-not $result -or -not $result.Body) {
            Write-ErrorLog "SKIPPED project '$projName' on repo page $pageNum — API returned null"
            $totalSkipped++
            $projFailed = $true
            break
        }

        $repos = $result.Body.value
        $count = if ($repos) { @($repos).Count } else { 0 }
        if ($count -gt 0) { $allRepos.AddRange($repos) }

        Write-Host "  Repo page $pageNum — $count repos (running total: $($allRepos.Count))"
        $repoContToken = $result.ContinuationToken

    } while ($repoContToken)

    if ($projFailed) { continue }

    if ($allRepos.Count -eq 0) {
        Write-Host "  No repos found"
        continue
    }

    # ── Fetch last push dates — parallel if > ParallelThreshold ──────────────
    if ($allRepos.Count -gt $ParallelThreshold) {
        Write-Host "  $($allRepos.Count) repos exceeds threshold ($ParallelThreshold) — fetching push dates in parallel ($ThrottleLimit threads)..." -ForegroundColor DarkCyan
        $pushDates = Get-PushDatesParallel `
            -Repos         $allRepos `
            -OrgName       $Org `
            -ProjectName   $projName `
            -AuthHeader    "Basic $auth" `
            -Threads       $ThrottleLimit `
            -Retries       $MaxRetries `
            -BatchDelayMs  $BatchDelayMs
    } else {
        Write-Host "  Fetching push dates sequentially for $($allRepos.Count) repos..." -ForegroundColor DarkCyan
        $pushDates = @{}
        foreach ($repo in $allRepos) {
            $pushDates[$repo.id] = Get-LastPushDateSequential -OrgName $Org -ProjectName $projName -RepoId $repo.id
        }
    }

    # ── Write a CSV row per repo ──────────────────────────────────────────────
    foreach ($repo in $allRepos) {
        $totalRepos++
        $projRepos++

        $lastPushDate   = if ($pushDates.ContainsKey($repo.id)) { $pushDates[$repo.id] } else { "Unknown" }
        $activityStatus = Get-ActivityStatus -LastPushDate $lastPushDate

        Write-CsvRow -Row ([PSCustomObject]@{
            Project        = $projName
            Repository     = $repo.name
            RepoUrl        = $repo.remoteUrl
            MetadataSizeMB = if ($repo.size) { [math]::Round($repo.size / 1MB, 2) } else { 0 }
            IsDisabled     = $repo.isDisabled
            LastPushDate   = $lastPushDate
            ActivityStatus = $activityStatus
        })
    }

    Write-Host "  Total repos: $projRepos" -ForegroundColor Green
}

# =============================================================================
#  SUMMARY
# =============================================================================
Write-Host "`n===== INVENTORY COMPLETE =====" -ForegroundColor Green
Write-Host "Total Projects  : $($allProjects.Count)"
Write-Host "Total Repos     : $totalRepos"
Write-Host "Skipped Projects: $totalSkipped"
Write-Host "Repo Inventory  : $OutputCsv"
if ($totalSkipped -gt 0) {
    Write-Host "Error Log       : $ErrorLog  (review skipped items)" -ForegroundColor Yellow
}