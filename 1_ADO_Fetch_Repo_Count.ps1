# ============================================================
#  ADO Repository Count Script
#  - Fetches all projects and repo counts
#  - Outputs results to a CSV file
# ============================================================

param (
    [string]$Org        = "Your_Azure_DevOps_Org",
    [string]$Pat        = "Your_Personal_Access_Token",
    [string]$OutputCsv  = "ado_repo_counts.csv",
    [string]$ErrorLog   = "ado_repo_counts_errors.log",
    [int]$PageSize      = 500,
    [int]$DelayMs       = 250,
    [int]$MaxRetries    = 6
)

$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
$headers = @{ Authorization = "Basic $auth" }

if (Test-Path $OutputCsv) { Remove-Item $OutputCsv -Force }
if (Test-Path $ErrorLog)  { Remove-Item $ErrorLog  -Force }

function Invoke-ADOApi {
    param ([string]$Url)

    $retry = 0
    while ($retry -lt $MaxRetries) {
        try {
            $raw       = Invoke-WebRequest -Uri $Url -Headers $headers -Method Get -ErrorAction Stop -UseBasicParsing
            $body      = $raw.Content | ConvertFrom-Json
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
                Write-Host "  [THROTTLED] HTTP $statusCode — waiting ${wait}s..." -ForegroundColor Yellow
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

# ── Fetch all projects ────────────────────────────────────────────────────────
Write-Host "`nFetching projects..." -ForegroundColor Cyan

$allProjects       = [System.Collections.Generic.List[object]]::new()
$continuationToken = $null

do {
    $url = "https://dev.azure.com/$Org/_apis/projects?`$top=100&api-version=7.1-preview.4"
    if ($continuationToken) { $url += "&continuationToken=$continuationToken" }

    Start-Sleep -Milliseconds $DelayMs
    $result = Invoke-ADOApi -Url $url

    if ($result -and $result.Body.value) {
        $allProjects.AddRange($result.Body.value)
        Write-Host "  Fetched $($allProjects.Count) projects so far..."
    } else {
        Add-Content -Path $ErrorLog -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))] Failed to fetch project page"
        break
    }
    $continuationToken = $result.ContinuationToken
} while ($continuationToken)

Write-Host "Total projects found: $($allProjects.Count)" -ForegroundColor Green

# ── Count repos per project and write CSV ────────────────────────────────────
$totalRepos = 0
$projIndex  = 0
$csvInit    = $false

foreach ($proj in $allProjects) {
    $projIndex++
    $projName  = $proj.name
    $repoCount = 0
    Write-Host "[$projIndex/$($allProjects.Count)] $projName" -ForegroundColor Cyan

    $skip      = 0
    $morePages = $true

    while ($morePages) {
        $url = "https://dev.azure.com/$Org/$([Uri]::EscapeDataString($projName))/_apis/git/repositories" +
               "?`$top=$PageSize&`$skip=$skip&api-version=7.1-preview.1"

        Start-Sleep -Milliseconds $DelayMs
        $result = Invoke-ADOApi -Url $url

        if (-not $result -or -not $result.Body) {
            Add-Content -Path $ErrorLog -Value "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))] SKIPPED repo page for '$projName' (skip=$skip)"
            break
        }

        $count = if ($result.Body.value) { @($result.Body.value).Count } else { 0 }
        $repoCount += $count

        if ($count -lt $PageSize) { $morePages = $false } else { $skip += $PageSize }
    }

    $totalRepos += $repoCount
    Write-Host "  Repos: $repoCount"

    $row = [PSCustomObject]@{ Project = $projName; RepoCount = $repoCount }
    if (-not $csvInit) {
        $row | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        $csvInit = $true
    } else {
        $row | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8 -Append
    }
}

Write-Host "`n===== COMPLETE =====" -ForegroundColor Green
Write-Host "Total Projects     : $($allProjects.Count)"
Write-Host "Total Repositories : $totalRepos"
Write-Host "Output CSV         : $OutputCsv"