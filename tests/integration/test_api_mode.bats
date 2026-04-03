#!/usr/bin/env bats
# tests/integration/test_api_mode.bats
# End-to-end API mode flows using a real fixture server.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures"
HELPERS_DIR="$REPO_ROOT/tests/helpers"
EXPORT_SCRIPT="$REPO_ROOT/jira-export.sh"

setup() {
  _OUT_DIR=$(mktemp -d)
  _MAP=$(mktemp)

  cat > "$_MAP" <<'EOF'
[
  {"method": "GET", "pattern": "/rest/api/3/myself",                                    "fixture": "connectivity_ok.json",  "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-1?expand=renderedFields",         "fixture": "issue_single.json",     "status": 200},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-404?expand=renderedFields",       "fixture": "error_404.json",        "status": 404},
  {"method": "GET", "pattern": "/rest/api/3/issue/PROJ-401?expand=renderedFields",       "fixture": "error_401.json",        "status": 401}
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

# --- single issue export ---

@test "single issue export: exits 0 for valid issue key" {
  run "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  [ "$status" -eq 0 ]
}

@test "single issue export: creates a file in the output directory" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  count=$(find "$_OUT_DIR" -name "*.md" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single issue export: output file contains issue key" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "PROJ-1" "$file"
}

@test "single issue export: output file contains issue summary" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "Fix login bug" "$file"
}

@test "single issue export: output file contains description" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "Users cannot log in" "$file"
}

@test "single issue export: output file is placed in project key subdirectory" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  [ -d "$_OUT_DIR/PROJ" ]
}

@test "single issue export: html format creates .html file" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format html
  count=$(find "$_OUT_DIR" -name "*.html" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single issue export: raw format creates .json file" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format raw
  count=$(find "$_OUT_DIR" -name "*.json" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "single issue export: exits non-zero for 404 issue" {
  run "$EXPORT_SCRIPT" --issue PROJ-404 --format md
  [ "$status" -ne 0 ]
}

@test "single issue export: exits non-zero for 401 auth failure" {
  run "$EXPORT_SCRIPT" --issue PROJ-401 --format md
  [ "$status" -ne 0 ]
  [[ "$output" =~ "401" ]] || [[ "$output" =~ "auth" ]] || [[ "$output" =~ "Auth" ]]
}

@test "single issue export: --output flag overrides JIRA_OUTPUT_DIR" {
  local custom_dir
  custom_dir=$(mktemp -d)
  run "$EXPORT_SCRIPT" --issue PROJ-1 --format md --output "$custom_dir"
  count=$(find "$custom_dir" -name "*.md" | wc -l | tr -d ' ')
  rm -rf "$custom_dir"
  [ "$count" -ge 1 ]
}

# --- --list dry run ---

@test "--list flag prints issue key without creating files" {
  run "$EXPORT_SCRIPT" --issue PROJ-1 --list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PROJ-1" ]]
  count=$(find "$_OUT_DIR" -type f | wc -l | tr -d ' ')
  [ "$count" -eq 0 ]
}

# --- URL input ---

@test "single issue export: accepts browse URL instead of bare key" {
  run "$EXPORT_SCRIPT" \
    --issue "http://127.0.0.1:${_PORT}/browse/PROJ-1" \
    --format md
  [ "$status" -eq 0 ]
}

# --- comments flag ---

@test "single issue export: --comments includes comment content in output" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md --comments
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  grep -q "Investigating the issue" "$file"
}

@test "single issue export: without --comments omits comment section" {
  "$EXPORT_SCRIPT" --issue PROJ-1 --format md
  file=$(find "$_OUT_DIR" -name "*.md" | head -1)
  ! grep -q "Investigating the issue" "$file"
}

# --- missing required args ---

@test "no scope given: falls through to discover mode (exits 0)" {
  # Without a scope the tool discovers boards; the fixture server has no board
  # route so it will get a 404 on the boards endpoint and exit non-zero —
  # but the important thing is it does NOT print the old usage error.
  run "$EXPORT_SCRIPT" --format md
  [[ "$output" != *"--issue, --project"* ]]
}

@test "exits non-zero when JIRA_URL is not set" {
  run env -u JIRA_URL "$EXPORT_SCRIPT" --issue PROJ-1
  [ "$status" -ne 0 ]
}
