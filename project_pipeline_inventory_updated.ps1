# ============================================================
#  ADO Pipeline Inventory Script
#  Compatible: PowerShell 5.1 (Windows) and PowerShell 7+ (macOS, Linux, Windows)
# ============================================================

param (
    [string]$Org                  = "",
    [string]$Pat                  = "",
    [string]$PipelineCsv          = "ado_pipeline_inventory.csv",
    [string]$ProjectCountCsv      = "ado_pipeline_project_counts.csv",
    [string]$ErrorLog             = "ado_pipeline_inventory_errors.log",
    [string]$RepoCsv              = "ado_pipeline_repo_counts.csv",
    [int]$DelayMs                 = 250,
    [int]$MaxRetries              = 6,
    [int]$MaxPagesPerScope        = 1000,
    [switch]$SkipReleasePipelines = $false
)

# =============================================================================
#  PRE-FLIGHT VALIDATION
#  Fails fast with a clear message before any real work begins.
# =============================================================================
if ([string]::IsNullOrWhiteSpace($Org)) {
    Write-Error "Parameter -Org is required. Example: -Org 'myorganisation'"
    exit 1
}
if ([string]::IsNullOrWhiteSpace($Pat)) {
    Write-Error "Parameter -Pat is required. Provide a Personal Access Token with Read access to Code and Pipelines."
    exit 1
}

Write-Host "`nValidating connectivity and PAT permissions..." -ForegroundColor Cyan

$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $auth" }

# Single cheap probe call — validates org name, PAT validity and network access
$probeUrl = "https://dev.azure.com/$Org/_apis/projects?`$top=1&api-version=7.1-preview.4"
try {
    Invoke-WebRequest -Uri $probeUrl -Headers $headers -Method Get `
        -ErrorAction Stop -UseBasicParsing | Out-Null
    Write-Host "  OK — org '$Org' reachable, PAT accepted." -ForegroundColor Green
}
catch {
    $sc = $null
    try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
    switch ($sc) {
        401     { Write-Error "Authentication failed (HTTP 401). PAT is incorrect or expired." }
        403     { Write-Error "Access denied (HTTP 403). PAT needs Read permission on Project, Code and Build." }
        404     { Write-Error "Organisation '$Org' not found (HTTP 404). Check the -Org value." }
        default { Write-Error "Cannot reach ADO (HTTP $sc). Check network connectivity and VPN." }
    }
    exit 1
}

# =============================================================================
#  INITIALISATION — clear previous outputs, detect PS version
# =============================================================================
foreach ($f in @($PipelineCsv, $ProjectCountCsv, $RepoCsv, $ErrorLog)) {
    if (Test-Path $f) { Remove-Item $f -Force }
}

# UTF8NoBOM on PS Core (v6+); UTF8 (with BOM) on PS5 — consistent across OS
$csvEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { "UTF8NoBOM" } else { "UTF8" }

$pipelineCsvInitialized = $false
$projectCsvInitialized  = $false
$repoCsvInitialized     = $false

Write-Host "  PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "  Encoding   : $csvEncoding"
Write-Host "  Releases   : $(if ($SkipReleasePipelines) { 'skipped' } else { 'included' })`n"

# =============================================================================
#  HELPER: safely read a header value on both PS5 (string) and PS Core (string[])
# =============================================================================
function Get-HeaderValue {
    param ([object]$Headers, [string]$Name)
    if ($null -eq $Headers) { return $null }
    try {
        if ($Headers.ContainsKey($Name)) {
            $val = $Headers[$Name]
            if ($val -is [System.Array]) { $val = $val[0] }
            if (![string]::IsNullOrWhiteSpace($val)) { return "$val" }
        }
    } catch {}
    return $null
}

function Wait-PoliteDelay { Start-Sleep -Milliseconds $script:DelayMs }

# =============================================================================
#  CORE API WRAPPER
#  - 429/503 throttling with Retry-After support
#  - Continuation token always $null or non-empty string (never "")
#  - PS5/PS Core safe throughout
# =============================================================================
function Invoke-ADOApi {
    param ([string]$Url)

    $retry = 0
    while ($retry -lt $script:MaxRetries) {
        try {
            $raw  = Invoke-WebRequest -Uri $Url -Headers $script:headers `
                    -Method Get -ErrorAction Stop -UseBasicParsing
            $body = $raw.Content | ConvertFrom-Json

            $contToken = $null
            $hv = Get-HeaderValue -Headers $raw.Headers -Name "x-ms-continuationtoken"
            if ($hv) {
                $contToken = $hv
            } elseif ($body.PSObject.Properties["continuationToken"]) {
                $v = $body.continuationToken
                if (![string]::IsNullOrWhiteSpace($v)) { $contToken = "$v" }
            }

            return [PSCustomObject]@{
                Body              = $body
                ContinuationToken = $contToken
            }
        }
        catch {
            $statusCode = $null
            try { if ($_.Exception.Response) { $statusCode = [int]$_.Exception.Response.StatusCode } } catch {}

            if ($statusCode -eq 429 -or $statusCode -eq 503) {
                $retryAfter = $null
                try {
                    $rv = Get-HeaderValue -Headers $_.Exception.Response.Headers -Name "Retry-After"
                    if ($rv) { $retryAfter = [int]$rv }
                } catch {}

                $wait = if ($retryAfter -and $retryAfter -gt 0) {
                    $retryAfter
                } else {
                    [math]::Min(120, [math]::Pow(2, $retry + 1))
                }

                Write-Host "  [THROTTLED] HTTP $statusCode — waiting ${wait}s (retry $($retry+1)/$($script:MaxRetries))..." -ForegroundColor Yellow
                Write-ErrorLog "[THROTTLED] HTTP $statusCode on $Url — waiting ${wait}s (retry $($retry+1)/$($script:MaxRetries))"
                Start-Sleep -Seconds $wait
                $retry++
            }
            else {
                Write-ErrorLog "[API ERROR] HTTP $statusCode — $Url"
                return $null
            }
        }
    }

    Write-ErrorLog "[MAX RETRIES] Giving up after $($script:MaxRetries) retries: $Url"
    return $null
}

# =============================================================================
#  CSV WRITERS — stream row-by-row; never buffer full dataset in memory
# =============================================================================
function Write-PipelineCsvRow {
    param ([PSCustomObject]$Row)
    if (-not $script:pipelineCsvInitialized) {
        $Row | Export-Csv -Path $script:PipelineCsv -NoTypeInformation -Encoding $script:csvEncoding
        $script:pipelineCsvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:PipelineCsv -NoTypeInformation -Encoding $script:csvEncoding -Append
    }
}

function Write-ProjectCountRow {
    param ([PSCustomObject]$Row)
    if (-not $script:projectCsvInitialized) {
        $Row | Export-Csv -Path $script:ProjectCountCsv -NoTypeInformation -Encoding $script:csvEncoding
        $script:projectCsvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:ProjectCountCsv -NoTypeInformation -Encoding $script:csvEncoding -Append
    }
}

function Write-RepoCsvRow {
    param ([PSCustomObject]$Row)
    if (-not $script:repoCsvInitialized) {
        $Row | Export-Csv -Path $script:RepoCsv -NoTypeInformation -Encoding $script:csvEncoding
        $script:repoCsvInitialized = $true
    } else {
        $Row | Export-Csv -Path $script:RepoCsv -NoTypeInformation -Encoding $script:csvEncoding -Append
    }
}

function Write-ErrorLog {
    param ([string]$Message)
    $ts = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $script:ErrorLog -Value "[$ts] $Message"
    # Intentionally not mirroring to console — at 50k repo scale every skipped item
    # printing to terminal floods output and makes progress unreadable.
    # All errors are in the error log file for review after the run completes.
}


# =============================================================================
#  BUILD PIPELINE FETCH — fetches ALL build pipelines for an entire project in
#  one paginated pass, then groups results by repository in memory.
#
#  WHY: The previous per-repo approach made 1 API call per repo regardless of
#  whether the repo had any pipelines. At 18k repos that is 18,000 API calls
#  plus 250ms delay each = 75+ minutes just waiting. A project-level fetch
#  makes only as many calls as there are pages of pipelines (typically <50
#  even for large projects) and is orders of magnitude faster.
#
#  Returns: hashtable of repoName → pipeline count, for repo CSV writing
# =============================================================================
function Get-BuildPipelinesForProject {
    param (
        [string]$ProjectName,
        [System.Collections.Generic.List[object]]$AllRepos   # full repo objects collected during paging
    )

    $repoCounts   = @{}   # repoName → count, accumulated during API phase
    $pipelineRows = [System.Collections.Generic.List[object]]::new()   # collected during API phase
    $totalCount   = 0
    $contToken    = $null
    $page         = 0

    # ── Phase 1: API only — collect all pipeline rows, no file writes ─────────
    while ($true) {
        $page++
        if ($page -gt $script:MaxPagesPerScope) {
            Write-ErrorLog "SAFETY CAP — build pipelines for '$ProjectName' hit $($script:MaxPagesPerScope) page limit"
            break
        }

        $url = "https://dev.azure.com/$script:Org/$([Uri]::EscapeDataString($ProjectName))/_apis/build/definitions" +
               "?`$top=100&api-version=7.1-preview.7"
        if ($contToken) { $url += "&continuationToken=$contToken" }

        Wait-PoliteDelay
        $result = Invoke-ADOApi -Url $url

        if (-not $result -or -not $result.Body) {
            Write-ErrorLog "SKIPPED build pipelines (page $page) for '$ProjectName' — API returned null."
            break
        }

        $defs = $result.Body.value
        if (-not $defs -or @($defs).Count -eq 0) { break }

        foreach ($def in $defs) {
            $totalCount++

            # repository.name is absent in the list response — confirmed via Postman.
            # Must fetch individual definition to get it. One extra call per pipeline.
            $repoName = ""
            $detailUrl = "https://dev.azure.com/$script:Org/$([Uri]::EscapeDataString($ProjectName))/_apis/build/definitions/$($def.id)?api-version=7.1-preview.7"
            Wait-PoliteDelay
            $detail = Invoke-ADOApi -Url $detailUrl
            if ($detail -and $detail.Body -and $detail.Body.repository -and $detail.Body.repository.name) {
                $repoName = $detail.Body.repository.name
            }

            if ($repoName -and -not $repoCounts.ContainsKey($repoName)) { $repoCounts[$repoName] = 0 }
            if ($repoName) { $repoCounts[$repoName]++ }

            $pipelineRows.Add([PSCustomObject]@{
                Project      = $ProjectName
                Repository   = $repoName
                PipelineName = $def.name
                PipelineType = "Build Pipeline"
                PipelineUrl  = if ($def._links.web) { $def._links.web.href } else { "" }
            })
        }

        if (-not $result.ContinuationToken) { break }
        $contToken = $result.ContinuationToken
    }

    # ── Phase 2: Write only — all API work done, no more calls ───────────────
    foreach ($row in $pipelineRows) {
        Write-PipelineCsvRow -Row $row
    }

    foreach ($repo in $AllRepos) {
        if ([string]::IsNullOrWhiteSpace($repo.name)) { continue }
        $pipCount = if ($repoCounts.ContainsKey($repo.name)) { $repoCounts[$repo.name] } else { 0 }
        Write-RepoCsvRow -Row ([PSCustomObject]@{
            Project       = $ProjectName
            Repository    = $repo.name
            PipelineCount = $pipCount
        })
    }

    return $totalCount
}

# =============================================================================
#  RELEASE PIPELINE FETCH — scoped to one project (vsrm host)
#  On failure: logs error, returns partial count, caller continues to next project
# =============================================================================
function Get-ReleasePipelinesForProject {
    param ([string]$ProjectName)

    $pipelineRows = [System.Collections.Generic.List[object]]::new()
    $count        = 0
    $contToken    = $null
    $page         = 0

    # ── Phase 1: API only — collect all release pipeline rows, no file writes ─
    while ($true) {
        $page++
        if ($page -gt $script:MaxPagesPerScope) {
            Write-ErrorLog "SAFETY CAP — release pipelines for '$ProjectName' hit $($script:MaxPagesPerScope) page limit"
            break
        }

        $url = "https://vsrm.dev.azure.com/$script:Org/$([Uri]::EscapeDataString($ProjectName))/_apis/release/definitions" +
               "?`$top=100&api-version=7.1-preview.4"
        if ($contToken) { $url += "&continuationToken=$contToken" }

        Wait-PoliteDelay
        $result = Invoke-ADOApi -Url $url

        if (-not $result -or -not $result.Body) {
            Write-ErrorLog "SKIPPED release pipelines (page $page) for '$ProjectName' — API returned null. Continuing to next project."
            break
        }

        $defs = $result.Body.value
        if (-not $defs -or @($defs).Count -eq 0) { break }

        foreach ($def in $defs) {
            $count++
            $pipelineRows.Add([PSCustomObject]@{
                Project      = $ProjectName
                Repository   = ""
                PipelineName = $def.name
                PipelineType = "Classic Release"
                PipelineUrl  = if ($def._links.web) { $def._links.web.href } else { "" }
            })
        }

        if (-not $result.ContinuationToken) { break }
        $contToken = $result.ContinuationToken
    }

    # ── Phase 2: Write only — all API work done, no more calls ───────────────
    foreach ($row in $pipelineRows) {
        Write-PipelineCsvRow -Row $row
    }

    return $count
}

# =============================================================================
#  STEP 1 — Fetch all projects (paginated)
#  On failure of a page: logs and breaks out — processes whatever was collected
# =============================================================================
Write-Host "Fetching projects..." -ForegroundColor Cyan

$allProjects = [System.Collections.Generic.List[object]]::new()
$contToken   = $null
$page        = 0

while ($true) {
    $page++
    if ($page -gt $MaxPagesPerScope) {
        Write-ErrorLog "SAFETY CAP — project list hit $MaxPagesPerScope page limit"
        break
    }

    $url = "https://dev.azure.com/$Org/_apis/projects?`$top=100&api-version=7.1-preview.4"
    if ($contToken) { $url += "&continuationToken=$contToken" }

    Wait-PoliteDelay
    $result = Invoke-ADOApi -Url $url

    if (-not $result -or -not $result.Body) {
        Write-ErrorLog "Failed to fetch project page $page — API returned null. Continuing with $($allProjects.Count) projects collected so far."
        break
    }

    $projects = $result.Body.value
    if (-not $projects -or @($projects).Count -eq 0) { break }

    $allProjects.AddRange($projects)
    Write-Host "  $($allProjects.Count) projects fetched..."

    if (-not $result.ContinuationToken) { break }
    $contToken = $result.ContinuationToken
}

$totalProjects = $allProjects.Count
Write-Host "Total projects: $totalProjects`n" -ForegroundColor Green

if ($totalProjects -eq 0) {
    Write-Error "No projects returned. Verify -Org and that the PAT has 'Project (Read)' scope."
    exit 1
}

# =============================================================================
#  STEP 2 — Per project:
#    2a. Page through all repos — collect names only (no pipeline calls per repo)
#    2b. ONE project-level build pipeline fetch — groups by repo in memory
#    2c. Release pipeline fetch — one paginated pass per project
#
#  Failure handling:
#  - Repo page failure    → log, mark project as partial, continue to pipeline fetch
#  - Pipeline page failure → log, partial results written
#  - Release page failure  → log, move to next project
#  - Project always gets a summary row written regardless of failure state
# =============================================================================
$totalPipelines  = 0
$totalRepos      = 0
$failedProjects  = 0
$projIndex       = 0
$startTime       = Get-Date

foreach ($proj in $allProjects) {
    $projIndex++
    $projName      = "$($proj.name)".Trim()
    if ([string]::IsNullOrWhiteSpace($projName)) {
        Write-ErrorLog "SKIPPED project at index $projIndex — name is empty or null in ADO response"
        continue
    }
    $projPipelines = 0
    $projPartial   = $false   # true if any page/repo failed — noted in counts CSV
    $repoContToken = $null
    $pageNum       = 0
    $allRepos      = [System.Collections.Generic.List[object]]::new()

    Write-Host "[$projIndex/$totalProjects] $projName" -ForegroundColor Cyan

    # ── 2a. Page through repos ─────────────────────────────────────────────
    while ($true) {
        $pageNum++
        if ($pageNum -gt $MaxPagesPerScope) {
            Write-ErrorLog "SAFETY CAP — repo paging for '$projName' hit $MaxPagesPerScope page limit. Partial results only."
            $projPartial = $true
            break
        }

        $repoUrl = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))/_apis/git/repositories?api-version=7.1-preview.1"
        if ($repoContToken) { $repoUrl += "&continuationToken=$repoContToken" }

        Wait-PoliteDelay
        $result = Invoke-ADOApi -Url $repoUrl

        if (-not $result -or -not $result.Body) {
            Write-ErrorLog "SKIPPED repo page $pageNum for '$projName' — API returned null. Continuing with repos collected so far."
            $projPartial = $true
            break
        }

        $repos     = $result.Body.value
        $pageCount = if ($repos) { @($repos).Count } else { 0 }
        if ($pageCount -eq 0) { break }

        $totalRepos    += $pageCount

        # Throttle console output — printing every repo name at 50k scale floods the terminal
        if ($allRepos.Count % 100 -eq 0 -or $pageNum -eq 1) {
            Write-Host "  Repos: $($allRepos.Count) (page $pageNum)" -ForegroundColor Gray
        }

        if ($repos) { $allRepos.AddRange($repos) }

        if (-not $result.ContinuationToken) { break }
        $repoContToken = $result.ContinuationToken
    }

    # ── 2b. Build pipelines — one project-level call, groups by repo in memory ──
    if ($allRepos.Count -eq 0) {
        Write-Host "  No repos found — skipping pipeline fetch" -ForegroundColor Gray
        $buildCount = 0
    } else {
        Write-Host "  Fetching build pipelines for project..." -ForegroundColor Gray
        $buildCount = Get-BuildPipelinesForProject -ProjectName $projName -AllRepos $allRepos
        Write-Host "  Build pipelines: $buildCount" -ForegroundColor Gray
    }
    $projPipelines  += $buildCount
    $totalPipelines += $buildCount

    # ── 2c. Release pipelines — always attempted even if repo paging was partial ──
    if (-not $SkipReleasePipelines) {
        $relCount       = Get-ReleasePipelinesForProject -ProjectName $projName
        $projPipelines += $relCount
        $totalPipelines += $relCount
    }

    # ── 2c. Project summary row — always written, Partial column flags degraded results ──
    Write-ProjectCountRow -Row ([PSCustomObject]@{
        Project       = $projName
        RepoCount     = $allRepos.Count
        PipelineCount = $projPipelines
    })

    if ($projPartial) {
        $failedProjects++
        Write-Host "  Partial — Repos: $($allRepos.Count) | Pipelines: $projPipelines (check error log)" -ForegroundColor Yellow
    } else {
        Write-Host "  Done    — Repos: $($allRepos.Count) | Pipelines: $projPipelines" -ForegroundColor Green
    }
}

# =============================================================================
#  SUMMARY
# =============================================================================
$duration = (Get-Date) - $startTime
Write-Host "`n===== PIPELINE INVENTORY COMPLETE =====" -ForegroundColor Green
Write-Host "Duration               : $([math]::Round($duration.TotalMinutes, 1)) minutes"
Write-Host "Total Projects         : $totalProjects"
Write-Host "Total Repos Scanned    : $totalRepos"
Write-Host "Total Pipelines Found  : $totalPipelines"
Write-Host "Projects with Errors   : $failedProjects $(if ($failedProjects -gt 0) { '(partial results — see error log)' })"
Write-Host ""
Write-Host "Pipeline Inventory CSV : $PipelineCsv"
Write-Host "Repo Pipeline Counts   : $RepoCsv"
Write-Host "Project Counts CSV     : $ProjectCountCsv"
if (Test-Path $ErrorLog) {
    Write-Host "Error Log              : $ErrorLog" -ForegroundColor Yellow
}