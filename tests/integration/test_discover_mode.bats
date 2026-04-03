#!/usr/bin/env bats
# tests/integration/test_discover_mode.bats
# Tests for discover mode: no scope given — fetches all accessible boards and exports them.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/jira-export.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"method": "GET", "pattern": "/rest/api/3/myself",                                        "fixture": "connectivity_ok.json",  "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board?startAt=0",                           "fixture": "boards_list.json",      "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board/1/issue?expand=renderedFields",        "fixture": "board_issues.json",     "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board/2/issue?expand=renderedFields",        "fixture": "board_issues.json",     "status": 200}
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

# --- discover mode (no scope given) ---

@test "discover mode: exits 0 when no scope is given" {
  run "$EXPORT_SCRIPT" --format md
  [ "$status" -eq 0 ]
}

@test "discover mode: exports issues from all accessible boards" {
  "$EXPORT_SCRIPT" --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  # 2 boards × 2 issues each = 4 (deduped by collision path if same issue key)
  [ "$count" -ge 2 ]
}

@test "discover mode: --list prints board names without creating files" {
  run "$EXPORT_SCRIPT" --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PROJ Scrum Board" ]]
  [[ "$output" =~ "TEAM Kanban Board" ]]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}

@test "discover mode: informs user which boards were found" {
  run "$EXPORT_SCRIPT" --format md
  [ "$status" -eq 0 ]
  [[ "$output" =~ "board" ]] || [[ "$output" =~ "Board" ]]
}

# --- no boards available ---

@test "discover mode: exits 0 with no files when no boards are accessible" {
  kill "$_SERVER_PID" 2>/dev/null || true
  wait "$_SERVER_PID" 2>/dev/null || true

  local empty_map
  empty_map=$(mktemp)
  cat > "$empty_map" <<'EOF'
[
  {"method": "GET", "pattern": "/rest/api/3/myself",             "fixture": "connectivity_ok.json",    "status": 200},
  {"method": "GET", "pattern": "/rest/agile/1.0/board?startAt=0","fixture": "boards_list_empty.json",  "status": 200}
]
EOF

  _PORT2=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
  python3 "$HELPERS_DIR/fixture_server.py" "$_PORT2" "$empty_map" >/dev/null 2>&1 &
  local empty_pid=$!
  local i=0
  until curl -s "http://127.0.0.1:${_PORT2}/" >/dev/null 2>&1 || [ $i -ge 30 ]; do
    sleep 0.1; i=$((i+1))
  done

  JIRA_URL="http://127.0.0.1:${_PORT2}" run "$EXPORT_SCRIPT" --format md
  local exit_status=$status

  kill "$empty_pid" 2>/dev/null || true
  wait "$empty_pid" 2>/dev/null || true
  rm -f "$empty_map"

  [ "$exit_status" -eq 0 ]
  file_count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$file_count" -eq 0 ]
}
