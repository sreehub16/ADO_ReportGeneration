#!/usr/bin/env bash
# ============================================================
#  ADO Repository Count Script (Bash)
#  - Fetches all projects and repo counts
#  - Outputs results to a CSV file
#  - continuationToken-based repo pagination (no $skip loop)
#  - Retry-After header respected with exponential backoff
#  - Safe throttle delays on every API call
#  - Skipped/failed project error log
# ============================================================

set -euo pipefail

# ── Defaults (override via env vars or edit here) ─────────────────────────────
ORG="${ADO_ORG:-Your_Azure_DevOps_Org}"
PAT="${ADO_PAT:-Your_Personal_Access_Token}"
OUTPUT_CSV="${OUTPUT_CSV:-ado_repo_counts.csv}"
ERROR_LOG="${ERROR_LOG:-ado_repo_counts_errors.log}"
DELAY_MS="${DELAY_MS:-250}"       # ms between every API call
MAX_RETRIES="${MAX_RETRIES:-6}"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl jq awk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# ── Clean up previous run outputs ─────────────────────────────────────────────
rm -f "$OUTPUT_CSV" "$ERROR_LOG"

# ── Auth header ───────────────────────────────────────────────────────────────
AUTH_HEADER="Authorization: Basic $(printf ':%s' "$PAT" | base64 | tr -d '\n')"

# ── Helpers ───────────────────────────────────────────────────────────────────
polite_delay() {
    sleep "$(awk "BEGIN {printf \"%.3f\", $DELAY_MS/1000}")"
}

log_error() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $msg" >> "$ERROR_LOG"
    echo "WARNING: $msg" >&2
}

# ── Core API wrapper ──────────────────────────────────────────────────────────
# Usage: invoke_ado_api <url>
# Prints JSON body to stdout.
# Sets global CONTINUATION_TOKEN from x-ms-continuationtoken header or JSON body.
CONTINUATION_TOKEN=""

invoke_ado_api() {
    local url="$1"
    local retry=0
    local response headers_file body status_code

    headers_file=$(mktemp)

    while [ "$retry" -lt "$MAX_RETRIES" ]; do
        # Dump response headers to temp file, body to stdout
        response=$(curl -s -w "%{http_code}" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -D "$headers_file" \
            "$url" 2>/dev/null)

        status_code="${response: -3}"
        body="${response%???}"   # strip last 3 chars (status code)

        if [ "$status_code" -eq 200 ]; then
            # Extract continuation token — prefer header, fall back to JSON body
            CONTINUATION_TOKEN=$(grep -i "x-ms-continuationtoken:" "$headers_file" \
                | awk '{print $2}' | tr -d '\r\n' || true)

            if [ -z "$CONTINUATION_TOKEN" ]; then
                CONTINUATION_TOKEN=$(echo "$body" | jq -r '.continuationToken // empty' 2>/dev/null | tr -d '\r' || true)
            fi

            rm -f "$headers_file"
            echo "$body"
            return 0
        elif [ "$status_code" -eq 429 ] || [ "$status_code" -eq 503 ]; then
            local retry_after
            retry_after=$(grep -i "retry-after:" "$headers_file" \
                | awk '{print $2}' | tr -d '\r\n' || true)

            local wait
            if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
                wait="$retry_after"
            else
                wait=$(awk "BEGIN {x=$((retry+1)); w=2^x; print (w>120?120:w)}")
            fi

            echo "  [THROTTLED] HTTP $status_code — waiting ${wait}s before retry $((retry+1))/$MAX_RETRIES..." >&2
            sleep "$wait"
            retry=$((retry+1))
        else
            echo "  [API ERROR] HTTP $status_code — $url" >&2
            rm -f "$headers_file"
            return 1
        fi
    done

    rm -f "$headers_file"
    echo "  [MAX RETRIES] Giving up on: $url" >&2
    return 1
}

# ── URL encode a string ───────────────────────────────────────────────────────
url_encode() {
    local string
    string=$(printf '%s' "$1" | tr -d '\r')
    printf '%s' "$string" | jq -sRr @uri
}

# =============================================================================
#  STEP 1 — Fetch all projects via continuationToken pagination
# =============================================================================
echo ""
echo "Fetching projects..."

# Write CSV header
echo "Project,RepoCount" > "$OUTPUT_CSV"

ALL_PROJECTS=()
cont_token=""
total_projects=0

while true; do
    url="https://dev.azure.com/${ORG}/_apis/projects?\$top=100&api-version=7.1-preview.4"
    if [ -n "$cont_token" ]; then
        url="${url}&continuationToken=${cont_token}"
    fi

    polite_delay
    body=$(invoke_ado_api "$url") || {
        log_error "Failed to fetch project page (continuationToken=$cont_token)"
        break
    }

    # Extract project names
    mapfile -t page_projects < <(echo "$body" | jq -r '.value[].name' | tr -d '\r')

    if [ ${#page_projects[@]} -eq 0 ]; then
        break
    fi

    ALL_PROJECTS+=("${page_projects[@]}")
    total_projects=${#ALL_PROJECTS[@]}
    echo "  Fetched $total_projects projects so far..."

    cont_token="$CONTINUATION_TOKEN"
    [ -z "$cont_token" ] && break
done

echo "Total projects found: $total_projects"

# =============================================================================
#  STEP 2 — For each project, fetch repo count via single API call
#  Uses continuationToken if ADO paginates (safe for any repo count)
# =============================================================================
total_repos=0
total_skipped=0
proj_index=0

for proj_name in "${ALL_PROJECTS[@]}"; do
    proj_index=$((proj_index+1))
    encoded_name=$(url_encode "$proj_name")
    repo_count=0
    page_num=0
    repo_cont_token=""

    echo ""
    echo "[$proj_index/$total_projects] $proj_name"

    while true; do
        page_num=$((page_num+1))
        url="https://dev.azure.com/${ORG}/${encoded_name}/_apis/git/repositories?api-version=7.1-preview.1"
        if [ -n "$repo_cont_token" ]; then
            url="${url}&continuationToken=${repo_cont_token}"
        fi

        polite_delay
        body=$(invoke_ado_api "$url") || {
            log_error "SKIPPED project '$proj_name' on page $page_num — API returned null"
            total_skipped=$((total_skipped+1))
            repo_count=-1   # sentinel so we skip CSV write
            break
        }

        count=$(echo "$body" | jq '.value | length')
        repo_count=$((repo_count+count))

        echo "  Page $page_num — $count repos (running total: $repo_count)"

        repo_cont_token="$CONTINUATION_TOKEN"
        [ -z "$repo_cont_token" ] && break
    done

    # Skip CSV write if project failed
    if [ "$repo_count" -eq -1 ]; then
        continue
    fi

    total_repos=$((total_repos+repo_count))
    echo "  Total repos: $repo_count"

    # Append to CSV — escape project name for CSV safety
    safe_name=$(printf '%s' "$proj_name" | sed 's/"/""/g')
    echo "\"${safe_name}\",${repo_count}" >> "$OUTPUT_CSV"
done

# =============================================================================
#  SUMMARY
# =============================================================================
echo ""
echo "===== COMPLETE ====="
echo "Total Projects     : $total_projects"
echo "Total Repositories : $total_repos"
echo "Skipped Projects   : $total_skipped"
echo "Output CSV         : $OUTPUT_CSV"
if [ "$total_skipped" -gt 0 ]; then
    echo "Error Log          : $ERROR_LOG  (review skipped items)"
fi