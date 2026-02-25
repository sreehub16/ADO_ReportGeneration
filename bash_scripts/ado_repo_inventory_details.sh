#!/usr/bin/env bash
# ============================================================
#  ADO Repository Inventory Script (Bash)
#  - Paginated project fetching via continuationToken
#  - Repo fetching via continuationToken (safe for 10k+ repos per project)
#  - No $skip — avoids infinite loop issue
#  - Retry-After header respected with exponential backoff
#  - Safe throttle delays on every API call
#  - Skipped/failed project error log
# ============================================================

# NOTE: intentionally NOT using set -e so a single failed project
# does not abort the entire run — errors are logged and skipped
set -uo pipefail

# ── Defaults (override via env vars or edit here) ─────────────────────────────
ORG="${ADO_ORG:-Your_Azure_DevOps_Org}"
PAT="${ADO_PAT:-Your_Personal_Access_Token}"
OUTPUT_CSV="${OUTPUT_CSV:-ado_repo_inventory.csv}"
PROJECT_COUNT_CSV="${PROJECT_COUNT_CSV:-ado_project_repo_counts.csv}"
ERROR_LOG="${ERROR_LOG:-ado_repo_inventory_errors.log}"
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
rm -f "$OUTPUT_CSV" "$PROJECT_COUNT_CSV" "$ERROR_LOG"

# ── Auth header ───────────────────────────────────────────────────────────────
AUTH_HEADER="Authorization: Basic $(printf ':%s' "$PAT" | base64 | tr -d '\n')"

# ── Temp file cleanup trap — runs on exit or kill ─────────────────────────────
HEADERS_FILE=""
PROJECTS_FILE=""
cleanup() {
    [ -n "$HEADERS_FILE" ] && rm -f "$HEADERS_FILE"
    [ -n "$PROJECTS_FILE" ] && rm -f "$PROJECTS_FILE"
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
# tr -d '\r' handles Git Bash on Windows where \r can sneak into strings
# safe no-op on Unix — \r simply won't be present
url_encode() {
    printf '%s' "$1" | tr -d '\r' | jq -sRr @uri
}

# ── CSV write helpers ─────────────────────────────────────────────────────────
INVENTORY_CSV_INITIALIZED=0
PROJECT_CSV_INITIALIZED=0

write_inventory_header() {
    printf 'Project,Repository,RepoUrl,MetadataSizeMB,IsDisabled\n' > "$OUTPUT_CSV"
    INVENTORY_CSV_INITIALIZED=1
}

write_inventory_row() {
    local project="$1" repo="$2" url="$3" size_mb="$4" disabled="$5"
    # Escape double quotes in each field
    project=$(printf '%s' "$project" | sed 's/"/""/g')
    repo=$(printf '%s' "$repo"       | sed 's/"/""/g')
    url=$(printf '%s' "$url"         | sed 's/"/""/g')
    printf '"%s","%s","%s",%s,%s\n' "$project" "$repo" "$url" "$size_mb" "$disabled" >> "$OUTPUT_CSV"
}

write_project_count_header() {
    printf 'Project,RepoCount\n' > "$PROJECT_COUNT_CSV"
    PROJECT_CSV_INITIALIZED=1
}

write_project_count_row() {
    local project="$1" count="$2"
    project=$(printf '%s' "$project" | sed 's/"/""/g')
    printf '"%s",%d\n' "$project" "$count" >> "$PROJECT_COUNT_CSV"
}

# ── Core API wrapper ──────────────────────────────────────────────────────────
# Prints JSON body to stdout on success.
# Sets global CONTINUATION_TOKEN from response header or JSON body.
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
                # Prefer header token, fall back to JSON body — tr -d '\r' on both
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
#  Written to a temp file (not array) — portable across all bash versions
#  and avoids memory issues at 500+ projects
# =============================================================================
echo ""
echo "Fetching projects..."

write_inventory_header
write_project_count_header

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

    # Write project names to temp file one per line — tr -d '\r' strips Windows line endings
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
#  STEP 2 — For each project fetch all repos via continuationToken
#
#  Key design decisions for scale:
#  - No $skip — ADO ignores it for large repo sets causing infinite loops
#  - continuationToken is server-driven — ADO controls pages, not us
#  - A project with 10k+ repos will paginate correctly via token
#  - A single failed project logs error and continues — does not abort run
# =============================================================================
total_repos=0
total_skipped=0
proj_index=0

while IFS= read -r proj_name; do
    # Skip blank lines
    [ -z "$proj_name" ] && continue

    proj_index=$((proj_index+1))
    proj_repos=0
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

        # Parse each repo field and write a row
        repo_count_on_page=$(printf '%s' "$body" | jq '.value | length')

        for i in $(seq 0 $((repo_count_on_page - 1))); do
            repo_name=$(printf '%s' "$body"    | jq -r ".value[$i].name"      | tr -d '\r')
            repo_url=$(printf '%s' "$body"     | jq -r ".value[$i].remoteUrl" | tr -d '\r')
            repo_size=$(printf '%s' "$body"    | jq -r ".value[$i].size // 0")
            repo_disabled=$(printf '%s' "$body"| jq -r ".value[$i].isDisabled")

            # Convert size bytes to MB with 2 decimal places
            size_mb=$(awk "BEGIN {printf \"%.2f\", $repo_size/1048576}")

            write_inventory_row "$proj_name" "$repo_name" "$repo_url" "$size_mb" "$repo_disabled"

            proj_repos=$((proj_repos+1))
            total_repos=$((total_repos+1))
        done

        echo "  Page $page_num — $repo_count_on_page repos (running total: $proj_repos)"

        # Capture token immediately after call — before next iteration overwrites it
        repo_cont_token="$CONTINUATION_TOKEN"
        [ -z "$repo_cont_token" ] && break
    done

    if [ "$proj_failed" -eq 1 ]; then
        # Write partial count to project CSV so at least something is recorded
        write_project_count_row "$proj_name" "$proj_repos"
        continue
    fi

    echo "  Total repos for project: $proj_repos"
    write_project_count_row "$proj_name" "$proj_repos"

done < "$PROJECTS_FILE"

rm -f "$PROJECTS_FILE"

# =============================================================================
#  SUMMARY
# =============================================================================
echo ""
echo "===== INVENTORY COMPLETE ====="
echo "Total Projects  : $total_projects"
echo "Total Repos     : $total_repos"
echo "Skipped Projects: $total_skipped"
echo "Repo Inventory  : $OUTPUT_CSV"
echo "Project Counts  : $PROJECT_COUNT_CSV"
if [ "$total_skipped" -gt 0 ]; then
    echo "Error Log       : $ERROR_LOG  (review skipped items)"
fi