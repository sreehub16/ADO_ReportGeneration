#!/usr/bin/env bash
# ============================================================
#  ADO Repository Count Script (Bash)
#  - Fetches all projects and repo counts
#  - Outputs results to a CSV file
#  - continuationToken-based pagination (no $skip loop)
#  - Retry-After header respected with exponential backoff
#  - Safe throttle delays on every API call
#  - Skipped/failed project error log
#  - Safe for large orgs (600+ projects, 30k+ repos)
# ============================================================

# does not abort the entire run — errors are logged and skipped
set -uo pipefail

# ── Defaults (override via env vars or edit here) ─────────────────────────────
ORG="${ADO_ORG:-Your_Azure_DevOps_Org}"
PAT="${ADO_PAT:-Your_Personal_Access_Token}"
OUTPUT_CSV="${OUTPUT_CSV:-ado_repo_counts.csv}"
ERROR_LOG="${ERROR_LOG:-ado_repo_counts_errors.log}"
DELAY_MS="${DELAY_MS:-250}"
MAX_RETRIES="${MAX_RETRIES:-6}"

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl jq awk base64 mktemp; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: '$cmd' is required but not installed." >&2
        exit 1
    fi
done

# ── Clean up previous run outputs ─────────────────────────────────────────────
rm -f "$OUTPUT_CSV" "$ERROR_LOG"

# ── Auth header ───────────────────────────────────────────────────────────────
AUTH_HEADER="Authorization: Basic $(printf ':%s' "$PAT" | base64 | tr -d '\n')"

# ── Temp file cleanup trap — runs on exit or kill ─────────────────────────────
HEADERS_FILE=""
cleanup() {
    [ -n "$HEADERS_FILE" ] && rm -f "$HEADERS_FILE"
}
trap cleanup EXIT INT TERM

# ── Helpers ───────────────────────────────────────────────────────────────────
polite_delay() {
    sleep "$(awk "BEGIN {printf \"%.3f\", $DELAY_MS/1000}")"
}

log_error() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $1" >> "$ERROR_LOG"
    echo "WARNING: $1" >&2
}

# ── URL encode ────────────────────────────────────────────────────────────────
url_encode() {
    # tr -d '\r' handles Git Bash on Windows where \r can sneak into strings
    printf '%s' "$1" | tr -d '\r' | jq -sRr @uri
}

# ── Core API wrapper ──────────────────────────────────────────────────────────
# Prints JSON body to stdout on success.
# Sets global CONTINUATION_TOKEN.
# Returns 0 on success, 1 on failure.
CONTINUATION_TOKEN=""

invoke_ado_api() {
    local url="$1"
    local retry=0
    local response body status_code retry_after wait

    HEADERS_FILE=$(mktemp)

    while [ "$retry" -lt "$MAX_RETRIES" ]; do
        response=$(curl -s -w "%{http_code}" \
            -H "$AUTH_HEADER" \
            -H "Content-Type: application/json" \
            -D "$HEADERS_FILE" \
            "$url" 2>/dev/null) || true

        status_code="${response: -3}"
        body="${response%???}"

        case "$status_code" in
            200)
                # Prefer header token, fall back to JSON body — strip \r on both
                CONTINUATION_TOKEN=$(grep -i "x-ms-continuationtoken:" "$HEADERS_FILE" \
                    | awk '{print $2}' | tr -d '\r\n' || true)

                if [ -z "$CONTINUATION_TOKEN" ]; then
                    CONTINUATION_TOKEN=$(printf '%s' "$body" \
                        | jq -r '.continuationToken // empty' 2>/dev/null \
                        | tr -d '\r' || true)
                fi

                rm -f "$HEADERS_FILE"
                HEADERS_FILE=""
                printf '%s' "$body"
                return 0
                ;;
            429|503)
                retry_after=$(grep -i "retry-after:" "$HEADERS_FILE" \
                    | awk '{print $2}' | tr -d '\r\n' || true)

                if [ -n "$retry_after" ] && [ "$retry_after" -gt 0 ] 2>/dev/null; then
                    wait="$retry_after"
                else
                    wait=$(awk "BEGIN {x=$((retry+1)); w=2^x; print (w>120?120:w)}")
                fi

                echo "  [THROTTLED] HTTP $status_code — waiting ${wait}s (retry $((retry+1))/$MAX_RETRIES)..." >&2
                sleep "$wait"
                retry=$((retry+1))
                ;;
            *)
                echo "  [API ERROR] HTTP $status_code — $url" >&2
                rm -f "$HEADERS_FILE"
                HEADERS_FILE=""
                return 1
                ;;
        esac
    done

    rm -f "$HEADERS_FILE"
    HEADERS_FILE=""
    echo "  [MAX RETRIES] Giving up on: $url" >&2
    return 1
}

# =============================================================================
#  STEP 1 — Fetch all projects via continuationToken pagination
#  Projects are written to a temp file instead of an array to avoid
#  bash array memory issues on systems with older bash versions
# =============================================================================
echo ""
echo "Fetching projects..."

echo "Project,RepoCount" > "$OUTPUT_CSV"

PROJECTS_FILE=$(mktemp)
cont_token=""
total_projects=0

while true; do
    url="https://dev.azure.com/${ORG}/_apis/projects?\$top=100&api-version=7.1-preview.4"
    [ -n "$cont_token" ] && url="${url}&continuationToken=${cont_token}"

    polite_delay
    body=$(invoke_ado_api "$url") || {
        log_error "Failed to fetch project page (continuationToken=$cont_token)"
        break
    }

    # Write project names to temp file — one per line, \r stripped
    page_count=$(printf '%s' "$body" | jq -r '.value[].name' | tr -d '\r' | tee -a "$PROJECTS_FILE" | wc -l)
    page_count=$(echo "$page_count" | tr -d ' ')

    if [ "$page_count" -eq 0 ]; then
        break
    fi

    total_projects=$((total_projects + page_count))
    echo "  Fetched $total_projects projects so far..."

    cont_token="$CONTINUATION_TOKEN"
    [ -z "$cont_token" ] && break
done

echo "Total projects found: $total_projects"

# =============================================================================
#  STEP 2 — For each project fetch repo count via continuationToken pagination
#  Safe for any repo count — no $skip, no infinite loop risk
# =============================================================================
total_repos=0
total_skipped=0
proj_index=0

while IFS= read -r proj_name; do
    # Skip blank lines
    [ -z "$proj_name" ] && continue

    proj_index=$((proj_index+1))
    repo_count=0
    page_num=0
    repo_cont_token=""
    proj_failed=0

    echo ""
    echo "[$proj_index/$total_projects] $proj_name"

    while true; do
        page_num=$((page_num+1))
        encoded_name=$(url_encode "$proj_name")
        url="https://dev.azure.com/${ORG}/${encoded_name}/_apis/git/repositories?api-version=7.1-preview.1"
        [ -n "$repo_cont_token" ] && url="${url}&continuationToken=${repo_cont_token}"

        polite_delay
        body=$(invoke_ado_api "$url") || {
            log_error "SKIPPED project '$proj_name' on page $page_num — API returned null"
            total_skipped=$((total_skipped+1))
            proj_failed=1
            break
        }

        count=$(printf '%s' "$body" | jq '.value | length')
        repo_count=$((repo_count+count))
        echo "  Page $page_num — $count repos (running total: $repo_count)"

        repo_cont_token="$CONTINUATION_TOKEN"
        [ -z "$repo_cont_token" ] && break
    done

    # Skip CSV write if this project failed — don't write partial counts
    if [ "$proj_failed" -eq 1 ]; then
        continue
    fi

    total_repos=$((total_repos+repo_count))
    echo "  Total repos: $repo_count"

    # CSV-safe project name — escape any double quotes
    safe_name=$(printf '%s' "$proj_name" | sed 's/"/""/g')
    printf '"%s",%d\n' "$safe_name" "$repo_count" >> "$OUTPUT_CSV"

done < "$PROJECTS_FILE"

rm -f "$PROJECTS_FILE"

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
