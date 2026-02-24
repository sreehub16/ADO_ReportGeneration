# ============================================================
#  ADO Repository Inventory Script
#  - Paginated project fetching
#  - Repo fetching via continuationToken (safe for 7k/10k+ repos per project)
#  - Retry-After header respected
#  - Safe throttle delays on every API call
#  - Skipped/failed project error log
#  - No empty CSV header row
#  - Separate project repo count CSV
# ============================================================

param (
    [string]$Org             = "",
    [string]$Pat             = "",
    [string]$OutputCsv       = "ado_repo_inventory.csv",
    [string]$ProjectCountCsv = "ado_project_repo_counts.csv",
    [string]$ErrorLog        = "ado_repo_inventory_errors.log",
    [int]$DelayMs             = 250,   # ms between every API call
    [int]$MaxRetries          = 6
)

# ── Auth ──────────────────────────────────────────────────────────────────────
$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $auth" }

# ── Clean up previous run outputs ─────────────────────────────────────────────
if (Test-Path $OutputCsv)       { Remove-Item $OutputCsv       -Force }
if (Test-Path $ProjectCountCsv) { Remove-Item $ProjectCountCsv -Force }
if (Test-Path $ErrorLog)        { Remove-Item $ErrorLog        -Force }

$csvInitialized        = $false
$projectCsvInitialized = $false

# ── Core API wrapper ──────────────────────────────────────────────────────────
function Invoke-ADOApi {
    param (
        [string]$Url,
        [int]$MaxRetries = $script:MaxRetries
    )

    $retry = 0
    while ($retry -lt $MaxRetries) {
        try {
            # Use Invoke-WebRequest so we can read response headers (continuation token, Retry-After)
            $raw   = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction Stop -UseBasicParsing
            $body  = $raw.Content | ConvertFrom-Json

            # Read continuation token — prefer response header, fall back to JSON body
            $contToken = $null
            if ($raw.Headers.ContainsKey("x-ms-continuationtoken")) {
                $contToken = $raw.Headers["x-ms-continuationtoken"]
            }
            if (-not $contToken -and $body.PSObject.Properties["continuationToken"]) {
                $contToken = $body.continuationToken
            }

            return [PSCustomObject]@{
                Body              = $body
                ContinuationToken = $contToken
            }
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 429 -or $statusCode -eq 503) {
                # Honour the Retry-After header when present; otherwise exponential back-off
                $retryAfter = $null
                try { $retryAfter = [int]$_.Exception.Response.Headers["Retry-After"] } catch {}

                $wait = if ($retryAfter -and $retryAfter -gt 0) {
                    $retryAfter
                } else {
                    [math]::Min(120, [math]::Pow(2, $retry + 1))
                }

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

# ── Helper: delay between every outbound call ─────────────────────────
function Wait-PoliteDelay {
    Start-Sleep -Milliseconds $DelayMs
}

# ── Helper: stream-append a repo row to the inventory CSV ────────────────────
function Write-CsvRow {
    param ([PSCustomObject]$Row)

    if (-not $script:csvInitialized) {
        $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8
        $script:csvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:OutputCsv -NoTypeInformation -Encoding UTF8 -Append
    }
}

# ── Helper: stream-append a project count row to the counts CSV ──────────────
function Write-ProjectCountRow {
    param ([PSCustomObject]$Row)

    if (-not $script:projectCsvInitialized) {
        $Row | Export-Csv -Path $script:ProjectCountCsv -NoTypeInformation -Encoding UTF8
        $script:projectCsvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:ProjectCountCsv -NoTypeInformation -Encoding UTF8 -Append
    }
}

# ── Helper: log skipped / failed items ───────────────────────────────────────
function Write-ErrorLog {
    param ([string]$Message)
    $timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $script:ErrorLog -Value "[$timestamp] $Message"
    Write-Warning $Message
}

# =============================================================================
#  STEP 1 — Fetch all projects in the organization, handling pagination
# =============================================================================
Write-Host "`nFetching projects..." -ForegroundColor Cyan

$allProjects       = [System.Collections.Generic.List[object]]::new()
$continuationToken = $null

do {
    $projUrl = "https://dev.azure.com/$Org/_apis/projects?`$top=100&api-version=7.1-preview.4"
    if ($continuationToken) {
        $projUrl += "&continuationToken=$continuationToken"
    }

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
#  STEP 2 — For each project, fetch all repositories via continuationToken
#
#
# =============================================================================
$totalRepos   = 0
$totalSkipped = 0
$projIndex    = 0

foreach ($proj in $allProjects) {
    $projIndex++
    $projName  = $proj.name
    $projRepos = 0
    $pageNum   = 0
    Write-Host "`n[$projIndex/$($allProjects.Count)] $projName" -ForegroundColor Cyan

    $repoContToken = $null
    $projFailed    = $false

    do {
        $pageNum++
        $repoUrl = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))/_apis/git/repositories?api-version=7.1-preview.1"
        if ($repoContToken) {
            $repoUrl += "&continuationToken=$repoContToken"
        }

        Wait-PoliteDelay
        $result = Invoke-ADOApi -Url $repoUrl

        if (-not $result -or -not $result.Body) {
            Write-ErrorLog "SKIPPED project '$projName' on page $pageNum — API returned null"
            $totalSkipped++
            $projFailed = $true
            break
        }

        $repos = $result.Body.value
        $count = if ($repos) { @($repos).Count } else { 0 }

        foreach ($repo in $repos) {
            $totalRepos++
            $projRepos++

            $metaSizeMB = if ($repo.size) {
                [math]::Round($repo.size / 1MB, 2)
            } else {
                0
            }

            Write-CsvRow -Row ([PSCustomObject]@{
                Project        = $projName
                Repository     = $repo.name
                RepoUrl        = $repo.remoteUrl
                MetadataSizeMB = $metaSizeMB
                IsDisabled     = $repo.isDisabled
            })
        }

        Write-Host "  Page $pageNum — $count repos (running total: $projRepos)"

        $repoContToken = $result.ContinuationToken

    } while ($repoContToken)

    if (-not $projFailed) {
        Write-Host "  Total repos for project: $projRepos" -ForegroundColor Green
    }

    # Write one summary row per project once all its pages are done
    Write-ProjectCountRow -Row ([PSCustomObject]@{
        Project   = $projName
        RepoCount = $projRepos
    })
}

# =============================================================================
#  SUMMARY
# =============================================================================
Write-Host "`n===== INVENTORY COMPLETE =====" -ForegroundColor Green
Write-Host "Total Projects  : $($allProjects.Count)"
Write-Host "Total Repos     : $totalRepos"
Write-Host "Skipped Projects: $totalSkipped"
Write-Host "Repo Inventory  : $OutputCsv"
Write-Host "Project Counts  : $ProjectCountCsv"
if ($totalSkipped -gt 0) {
    Write-Host "Error Log       : $ErrorLog  (review skipped items)" -ForegroundColor Yellow
}