#!/usr/bin/env bats
# tests/integration/test_export_scope.bats
# Tests for --project, --board, and --jql export scopes.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/jira-export.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"method": "GET", "pattern": "/rest/api/3/myself",                                                          "fixture": "connectivity_ok.json",    "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-1?expand=renderedFields",                              "fixture": "issue_single.json",       "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/search?jql=project+%3D+PROJ",                                    "fixture": "search_results.json",     "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/search?jql=project+%3D+EMPTY",                                   "fixture": "search_empty.json",       "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/search?jql=status+%3D+%22In+Progress%22",                        "fixture": "search_results.json",     "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board/42/issue?expand=renderedFields",                        "fixture": "board_issues.json",       "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board/99/issue?expand=renderedFields",                        "fixture": "search_empty.json",       "status": 200}
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
  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_EMAIL=user@example.com
  export JIRA_TOKEN=testtoken
  export JIRA_OUTPUT_DIR="$_OUT_DIR"
}

teardown() {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true
  rm -f "$_MAP"
  rm -rf "$_OUT_DIR"
}

# --- project export ---

@test "project export: exits 0" {
  run "$EXPORT_SCRIPT" --project PROJ --format md
  [ "$status" -eq 0 ]
}

@test "project export: creates a file per issue" {
  "$EXPORT_SCRIPT" --project PROJ --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "project export: uses project key as output directory" {
  "$EXPORT_SCRIPT" --project PROJ --format md
  [ -d "$_OUT_DIR/PROJ" ]
}

@test "project export: --list prints issue keys without creating files" {
  run "$EXPORT_SCRIPT" --project PROJ --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PROJ-1" ]]
  [[ "$output" =~ "PROJ-2" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

@test "project export: empty project exits 0 and creates no files" {
  run "$EXPORT_SCRIPT" --project EMPTY --format md
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- board export ---

@test "board export: exits 0" {
  run "$EXPORT_SCRIPT" --board 42 --format md
  [ "$status" -eq 0 ]
}

@test "board export: creates a file per issue" {
  "$EXPORT_SCRIPT" --board 42 --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -eq 2 ]
}

@test "board export: --list prints issue keys without creating files" {
  run "$EXPORT_SCRIPT" --board 42 --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PROJ-1" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

@test "board export: empty board exits 0 and creates no files" {
  run "$EXPORT_SCRIPT" --board 99 --format md
  [ "$status" -eq 0 ]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- JQL export ---

@test "jql export: exits 0" {
  run "$EXPORT_SCRIPT" --jql 'status+%3D+"In+Progress"' --format md
  [ "$status" -eq 0 ]
}

@test "jql export: creates files for matching issues" {
  "$EXPORT_SCRIPT" --jql 'status+%3D+"In+Progress"' --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "jql export: --list prints matching issue keys without files" {
  run "$EXPORT_SCRIPT" --jql 'status+%3D+"In+Progress"' --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PROJ" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

# --- pagination ---

@test "project export: collects all issues across paginated responses" {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true

  local pag_map
  pag_map=$(mktemp)
  cat > "$pag_map" <<'EOF'
[
  {"method": "GET", "pattern": "/rest/api/3/myself",                                                          "fixture": "connectivity_ok.json",        "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/search?jql=project+%3D+PROJ&startAt=0&maxResults=1",             "fixture": "search_results_page1.json",   "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/search?jql=project+%3D+PROJ&startAt=1&maxResults=1",             "fixture": "search_results_page2.json",   "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-1?expand=renderedFields",                              "fixture": "issue_single.json",           "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-2?expand=renderedFields",                              "fixture": "issue_single.json",           "status": 200}
]
EOF

  _PORT2=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT2" "$pag_map" >/dev/null 2>&1 &
  local pag_pid=$!
  local i=0
  until curl -s "http://127.0.0.1:${_PORT2}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  JIRA_URL="http://127.0.0.1:${_PORT2}" \
  JIRA_SEARCH_PAGE_SIZE=1 \
    "$EXPORT_SCRIPT" --project PROJ --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')

  kill "$pag_pid" 2>/dev/null || true
  wait "$pag_pid" 2>/dev/null || true
  rm -f "$pag_map"

  [ "$count" -ge 2 ]
}

# --- --force flag ---

@test "--force overwrites existing output files" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  printf 'old content' > "$file"
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md --force
  result=$(cat "$file")
  [[ "$result" != "old content" ]]
}
