#!/usr/bin/env bash
# lib/api.sh - Jira REST API calls, pagination, and retry logic

# Build the base REST API URL (Cloud v3, Server v2)
api_base_url() {
  local base="${JIRA_URL%/}"
  if [ "${JIRA_TYPE:-cloud}" = "cloud" ]; then
    printf '%s/rest/api/3' "$base"
  else
    printf '%s/rest/api/2' "$base"
  fi
}

# Build the Agile API URL (boards, sprints)
api_agile_url() {
  printf '%s/rest/agile/1.0' "${JIRA_URL%/}"
}

# Core curl wrapper with retry logic and auth headers
# Usage: api_curl <url> [extra_curl_args...]
# Writes response body to stdout; exports API_LAST_HTTP_CODE
api_curl() {
  local url="$1"; shift
  local auth_header
  auth_header=$(auth_build_header)

  local attempt=1
  local max_retries="${JIRA_MAX_RETRIES:-3}"
  local retry_delay="${JIRA_RETRY_DELAY:-5}"
  local tmp_body
  tmp_body=$(mktemp)

  while [ "$attempt" -le "$max_retries" ]; do
    log_debug "curl attempt ${attempt}/${max_retries}: $url"
    API_LAST_HTTP_CODE=$(curl -s -w "%{http_code}" -o "$tmp_body" \
      -H "Authorization: ${auth_header}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      "$@" \
      "$url" 2>/dev/null)

    case "$API_LAST_HTTP_CODE" in
      200|201)
        cat "$tmp_body"
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        return 0
        ;;
      401|403)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Authentication failed (HTTP ${API_LAST_HTTP_CODE}) for: $url"
        return 1
        ;;
      404)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Not found (HTTP 404): $url"
        return 1
        ;;
      429)
        local wait_time="$retry_delay"
        log_warn "Rate limited (HTTP 429). Waiting ${wait_time}s before retry ${attempt}/${max_retries}..."
        sleep "$wait_time"
        retry_delay=$((retry_delay * 2))
        attempt=$((attempt + 1))
        ;;
      000)
        rm -f "$tmp_body"
        export API_LAST_HTTP_CODE
        log_error "Network error: could not connect to ${JIRA_URL}"
        return 2
        ;;
      *)
        log_warn "HTTP ${API_LAST_HTTP_CODE} from API (attempt ${attempt}/${max_retries})"
        attempt=$((attempt + 1))
        sleep "$retry_delay"
        ;;
    esac
  done

  rm -f "$tmp_body"
  log_error "API request failed after ${max_retries} attempts: $url"
  return 2
}

# Extract an issue key from a Jira URL, or return it if already a bare key
# Handles:
#   https://site.atlassian.net/browse/PROJ-123
#   https://site.atlassian.net/jira/software/projects/PROJ/issues/PROJ-123
#   Bare key: PROJ-123
api_url_to_key() {
  local input="$1"

  # Already a bare issue key (letters, hyphen, digits — no slashes)
  if printf '%s' "$input" | grep -qE '^[A-Z][A-Z0-9]+-[0-9]+$'; then
    printf '%s' "$input"
    return 0
  fi

  # /browse/PROJ-123
  local key
  key=$(printf '%s' "$input" | sed -n 's|.*/browse/\([A-Z][A-Z0-9]*-[0-9][0-9]*\).*|\1|p')
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  # /issues/PROJ-123 (software project URL)
  key=$(printf '%s' "$input" | sed -n 's|.*/issues/\([A-Z][A-Z0-9]*-[0-9][0-9]*\).*|\1|p')
  if [ -n "$key" ]; then
    printf '%s' "$key"
    return 0
  fi

  log_error "Could not extract issue key from: $input"
  return 1
}

# Fetch a single issue with rendered fields
# Usage: api_get_issue <issue_key>
api_get_issue() {
  local key="$1"
  local base
  base=$(api_base_url)
  local fields="summary,status,issuetype,priority,assignee,reporter,labels,components,fixVersions,created,updated,comment"
  log_debug "Fetching issue: $key"
  api_curl "${base}/issue/${key}?expand=renderedFields&fields=${fields}"
}

# Search issues with JQL; appends compact JSON objects (one per line) to out_file
# Usage: api_search_issues <jql_encoded> <out_file>
api_search_issues() {
  local jql="$1"
  local out_file="$2"
  local base start=0
  local page_size="${JIRA_SEARCH_PAGE_SIZE:-50}"
  base=$(api_base_url)
  local fields="summary,status,issuetype,priority,assignee,reporter,labels,components,fixVersions,created,updated"

  while true; do
    local url="${base}/search?jql=${jql}&startAt=${start}&maxResults=${page_size}&expand=renderedFields&fields=${fields}"
    log_debug "Searching: $url"
    local response
    response=$(api_curl "$url") || return 1

    if [ "${HAS_JQ:-0}" = "1" ]; then
      printf '%s' "$response" | jq -c '.issues[]?' 2>/dev/null >> "$out_file"

      local total count
      total=$(printf '%s' "$response" | jq -r '.total // 0')
      count=$(printf '%s' "$response" | jq '.issues | length' 2>/dev/null || echo 0)
      start=$((start + count))
      if [ "$count" -eq 0 ] || [ "$start" -ge "$total" ]; then
        break
      fi
    else
      # No jq: extract issue objects with awk, no pagination
      printf '%s' "$response" | awk '
        BEGIN { depth=0; capture=0; buf="" }
        /"issues"[[:space:]]*:\[/ { capture=1; next }
        capture && /^\s*\{/ && depth==0 { depth=1; buf=$0"\n"; next }
        capture && depth>0 {
          buf=buf $0 "\n"
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1)
            if(c=="{") depth++
            if(c=="}") depth--
          }
          if(depth<=0){ print buf; buf=""; next }
        }
      ' >> "$out_file"
      break
    fi
  done
}

# Fetch all issues from an agile board; appends compact JSON objects to out_file
# Usage: api_get_board_issues <board_id> <out_file>
api_get_board_issues() {
  local board_id="$1"
  local out_file="$2"
  local agile start=0
  local page_size="${JIRA_SEARCH_PAGE_SIZE:-50}"
  agile=$(api_agile_url)

  while true; do
    local url="${agile}/board/${board_id}/issue?expand=renderedFields&startAt=${start}&maxResults=${page_size}"
    log_debug "Fetching board issues: $url"
    local response
    response=$(api_curl "$url") || return 1

    if [ "${HAS_JQ:-0}" = "1" ]; then
      printf '%s' "$response" | jq -c '.issues[]?' 2>/dev/null >> "$out_file"

      local total count
      total=$(printf '%s' "$response" | jq -r '.total // 0')
      count=$(printf '%s' "$response" | jq '.issues | length' 2>/dev/null || echo 0)
      start=$((start + count))
      if [ "$count" -eq 0 ] || [ "$start" -ge "$total" ]; then
        break
      fi
    else
      printf '%s' "$response" | awk '
        BEGIN { depth=0; capture=0; buf="" }
        /"issues"[[:space:]]*:\[/ { capture=1; next }
        capture && /^\s*\{/ && depth==0 { depth=1; buf=$0"\n"; next }
        capture && depth>0 {
          buf=buf $0 "\n"
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1)
            if(c=="{") depth++
            if(c=="}") depth--
          }
          if(depth<=0){ print buf; buf=""; next }
        }
      ' >> "$out_file"
      break
    fi
  done
}

# --- JSON field extractors ---

api_extract_key() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.key // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"key":"[^"]*"' | head -1 \
      | sed 's/"key":"//;s/"//'
  fi
}

api_extract_id() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"id":"[^"]*"' | head -1 \
      | sed 's/"id":"//;s/"//'
  fi
}

api_extract_summary() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.summary // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"summary":"[^"]*"' | head -1 \
      | sed 's/"summary":"//;s/"//'
  fi
}

api_extract_status() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.status.name // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"status":{"name":"[^"]*"' | head -1 \
      | sed 's/.*"name":"//;s/"//'
  fi
}

api_extract_type() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.issuetype.name // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"issuetype":{"name":"[^"]*"' | head -1 \
      | sed 's/.*"name":"//;s/"//'
  fi
}

api_extract_priority() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.priority.name // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"priority":{"name":"[^"]*"' | head -1 \
      | sed 's/.*"name":"//;s/"//'
  fi
}

api_extract_assignee() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.assignee.displayName // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"assignee":{"displayName":"[^"]*"' | head -1 \
      | sed 's/.*"displayName":"//;s/"//'
  fi
}

api_extract_reporter() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.reporter.displayName // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"reporter":{"displayName":"[^"]*"' | head -1 \
      | sed 's/.*"displayName":"//;s/"//'
  fi
}

api_extract_labels() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.labels // [] | join(",")' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"labels":\[[^]]*\]' | head -1 \
      | sed 's/"labels":\[//;s/\]//;s/"//g'
  fi
}

api_extract_created() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.created // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"created":"[^"]*"' | head -1 \
      | sed 's/"created":"//;s/"//'
  fi
}

api_extract_updated() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.fields.updated // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"updated":"[^"]*"' | head -1 \
      | sed 's/"updated":"//;s/"//'
  fi
}

api_extract_description_html() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.renderedFields.description // empty' 2>/dev/null
  else
    # Best-effort: won't handle all cases without jq
    printf '%s' "$json" | grep -o '"description":"[^"]*"' | head -1 \
      | sed 's/"description":"//;s/"$//' | sed 's/\\n/\n/g;s/\\"/"/g'
  fi
}

# Fetch all boards accessible to the authenticated user; appends compact JSON objects to out_file
# Usage: api_get_all_boards <out_file>
api_get_all_boards() {
  local out_file="$1"
  local agile start=0
  local page_size="${JIRA_SEARCH_PAGE_SIZE:-50}"
  agile=$(api_agile_url)

  while true; do
    local url="${agile}/board?startAt=${start}&maxResults=${page_size}"
    log_debug "Fetching boards: $url"
    local response
    response=$(api_curl "$url") || return 1

    if [ "${HAS_JQ:-0}" = "1" ]; then
      printf '%s' "$response" | jq -c '.values[]?' 2>/dev/null >> "$out_file"

      local is_last total count
      is_last=$(printf '%s' "$response" | jq -r '.isLast // true')
      count=$(printf '%s' "$response" | jq '.values | length' 2>/dev/null || echo 0)
      start=$((start + count))
      if [ "$is_last" = "true" ] || [ "$count" -eq 0 ]; then
        break
      fi
    else
      printf '%s' "$response" | awk '
        BEGIN { depth=0; capture=0; buf="" }
        /"values"[[:space:]]*:\[/ { capture=1; next }
        capture && /^\s*\{/ && depth==0 { depth=1; buf=$0"\n"; next }
        capture && depth>0 {
          buf=buf $0 "\n"
          for(i=1;i<=length($0);i++){
            c=substr($0,i,1)
            if(c=="{") depth++
            if(c=="}") depth--
          }
          if(depth<=0){ print buf; buf=""; next }
        }
      ' >> "$out_file"
      break
    fi
  done
}

api_extract_board_id() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.id // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"id":[0-9]*' | head -1 | sed 's/"id"://'
  fi
}

api_extract_board_name() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '.name // empty' 2>/dev/null
  else
    printf '%s' "$json" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//'
  fi
}

# Returns comments as newline-delimited records: "author|date|body_html"
# Usage: api_extract_comments_raw <issue_json>
api_extract_comments_raw() {
  local json="$1"
  if [ "${HAS_JQ:-0}" = "1" ]; then
    printf '%s' "$json" | jq -r '
      .renderedFields.comment.comments[]? |
      [
        (.author.displayName // "Unknown"),
        (.created // "" | .[0:10]),
        (.body // "")
      ] | @tsv
    ' 2>/dev/null
  fi
  # No jq fallback for comments (too complex without proper JSON parsing)
}
