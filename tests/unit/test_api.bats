#!/usr/bin/env bats
# tests/unit/test_api.bats
# Tests api.sh functions against a live fixture server (real curl, real HTTP).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"

setup_file() {
  export FIXTURES_DIR
}

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  source "$REPO_ROOT/lib/api.sh"

  deps_check

  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_EMAIL=user@example.com
  export JIRA_TOKEN=testtoken
  export JIRA_MAX_RETRIES=1
  export JIRA_RETRY_DELAY=0

  _MAP=$(mktemp)
  cat > "$_MAP" <<'EOF'
[
  {"method": "GET",  "pattern": "/rest/api/3/myself",                                      "fixture": "connectivity_ok.json",    "status": 200},
  {"method": "GET",  "pattern": "/rest/api/3/issue/PROJ-1?expand=renderedFields",           "fixture": "issue_single.json",       "status": 200},
  {"method": "GET",  "pattern": "/rest/api/3/issue/PROJ-404?expand=renderedFields",         "fixture": "error_404.json",          "status": 404},
  {"method": "GET",  "pattern": "/rest/api/3/issue/PROJ-401?expand=renderedFields",         "fixture": "error_401.json",          "status": 401},
  {"method": "GET",  "pattern": "/rest/api/3/search?jql=project+%3D+PROJ",                 "fixture": "search_results.json",     "status": 200},
  {"method": "GET",  "pattern": "/rest/api/3/search?jql=project+%3D+EMPTY",                "fixture": "search_empty.json",       "status": 200},
  {"method": "GET",  "pattern": "/rest/agile/1.0/board/42/issue?expand=renderedFields",     "fixture": "board_issues.json",       "status": 200},
  {"method": "GET",  "pattern": "/rest/agile/1.0/board?startAt=0",                          "fixture": "boards_list.json",        "status": 200}
]
EOF

  _PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT" "$_MAP" >/dev/null 2>&1 &
  _SERVER_PID=$!

  local i=0
  until curl -s "http://127.0.0.1:${_PORT}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  export JIRA_URL="http://127.0.0.1:${_PORT}"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
}

# --- api_base_url ---

@test "api_base_url: returns Cloud v3 path for cloud type" {
  export JIRA_TYPE=cloud
  export JIRA_URL=https://mysite.atlassian.net
  result=$(api_base_url)
  [ "$result" = "https://mysite.atlassian.net/rest/api/3" ]
}

@test "api_base_url: returns v2 path for server type" {
  export JIRA_TYPE=server
  export JIRA_URL=https://jira.example.com
  result=$(api_base_url)
  [ "$result" = "https://jira.example.com/rest/api/2" ]
}

@test "api_base_url: strips trailing slash from JIRA_URL" {
  export JIRA_TYPE=cloud
  export JIRA_URL=https://mysite.atlassian.net/
  result=$(api_base_url)
  [ "$result" = "https://mysite.atlassian.net/rest/api/3" ]
}

@test "api_agile_url: returns agile API path" {
  export JIRA_URL=https://mysite.atlassian.net
  result=$(api_agile_url)
  [ "$result" = "https://mysite.atlassian.net/rest/agile/1.0" ]
}

# --- api_url_to_key ---

@test "api_url_to_key: returns bare issue key unchanged" {
  result=$(api_url_to_key "PROJ-123")
  [ "$result" = "PROJ-123" ]
}

@test "api_url_to_key: extracts key from Cloud /browse/KEY-123 URL" {
  result=$(api_url_to_key "https://mysite.atlassian.net/browse/PROJ-123")
  [ "$result" = "PROJ-123" ]
}

@test "api_url_to_key: extracts key from Cloud software project URL" {
  result=$(api_url_to_key "https://mysite.atlassian.net/jira/software/projects/PROJ/issues/PROJ-123")
  [ "$result" = "PROJ-123" ]
}

@test "api_url_to_key: fails on unrecognised URL format" {
  run api_url_to_key "https://not-a-jira-url.example.com/something"
  [ "$status" -ne 0 ]
}

# --- api_get_issue ---

@test "api_get_issue: returns issue JSON for valid key" {
  result=$(api_get_issue "PROJ-1")
  [ "${HAS_JQ}" = "1" ] || skip "jq required for this assertion"
  key=$(printf '%s' "$result" | jq -r '.key')
  [ "$key" = "PROJ-1" ]
}

@test "api_get_issue: fails with exit code 1 for 404" {
  run api_get_issue "PROJ-404"
  [ "$status" -eq 1 ]
}

@test "api_get_issue: fails with exit code 1 for 401" {
  run api_get_issue "PROJ-401"
  [ "$status" -eq 1 ]
}

# --- api_search_issues ---

@test "api_search_issues: returns issues for valid JQL" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_search_issues "project+%3D+PROJ" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

@test "api_search_issues: returns empty file for zero-result JQL" {
  out=$(mktemp)
  api_search_issues "project+%3D+EMPTY" "$out"
  count=$(wc -c < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 0 ]
}

# --- api_get_board_issues ---

@test "api_get_board_issues: returns issues for valid board ID" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_board_issues "42" "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

# --- api_extract_* ---

@test "api_extract_key: returns key from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_key "$json")
  [ "$result" = "PROJ-1" ]
}

@test "api_extract_summary: returns summary from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_summary "$json")
  [ "$result" = "Fix login bug" ]
}

@test "api_extract_status: returns status name from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_status "$json")
  [ "$result" = "In Progress" ]
}

@test "api_extract_type: returns issue type from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_type "$json")
  [ "$result" = "Bug" ]
}

@test "api_extract_priority: returns priority from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_priority "$json")
  [ "$result" = "High" ]
}

@test "api_extract_assignee: returns assignee display name from issue JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_assignee "$json")
  [ "$result" = "John Doe" ]
}

@test "api_extract_reporter: returns reporter display name from issue JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_reporter "$json")
  [ "$result" = "Jane Smith" ]
}

@test "api_extract_description_html: returns rendered description HTML" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_description_html "$json")
  [[ "$result" =~ "Users cannot log in." ]]
}

@test "api_extract_created: returns created date from issue JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_created "$json")
  [[ "$result" =~ "2024-01-15" ]]
}

@test "api_extract_labels: returns labels as comma-separated string" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_labels "$json")
  [[ "$result" =~ "auth" ]]
  [[ "$result" =~ "login" ]]
}

@test "api_extract_id: returns numeric id from issue JSON" {
  json=$(cat "$FIXTURES_DIR/issue_single.json")
  result=$(api_extract_id "$json")
  [ "$result" = "10001" ]
}

# --- api_get_all_boards ---

@test "api_get_all_boards: returns board objects from agile API" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_all_boards "$out"
  count=$(wc -l < "$out" | tr -d ' ')
  rm -f "$out"
  [ "$count" -eq 2 ]
}

@test "api_get_all_boards: each line contains a board id" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  out=$(mktemp)
  api_get_all_boards "$out"
  first=$(head -1 "$out")
  rm -f "$out"
  id=$(printf '%s' "$first" | jq -r '.id')
  [ "$id" = "1" ]
}

# --- api_extract_board_* ---

@test "api_extract_board_id: returns id from board JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/boards_list.json")
  first=$(printf '%s' "$json" | jq -c '.values[0]')
  result=$(api_extract_board_id "$first")
  [ "$result" = "1" ]
}

@test "api_extract_board_name: returns name from board JSON" {
  [ "${HAS_JQ}" = "1" ] || skip "jq required"
  json=$(cat "$FIXTURES_DIR/boards_list.json")
  first=$(printf '%s' "$json" | jq -c '.values[0]')
  result=$(api_extract_board_name "$first")
  [ "$result" = "PROJ Scrum Board" ]
}
