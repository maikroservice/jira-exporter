#!/usr/bin/env bats
# tests/unit/test_output.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/output.sh"
  _TMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$_TMP_DIR"
}

# --- output_slugify ---

@test "output_slugify: lowercases input" {
  result=$(output_slugify "UPPER CASE")
  [[ "$result" =~ ^[a-z-]+$ ]]
}

@test "output_slugify: converts spaces to hyphens" {
  result=$(output_slugify "hello world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: strips non-alphanumeric characters except hyphens" {
  result=$(output_slugify "hello! world@2024")
  [ "$result" = "hello-world-2024" ]
}

@test "output_slugify: collapses consecutive hyphens" {
  result=$(output_slugify "hello---world")
  [ "$result" = "hello-world" ]
}

@test "output_slugify: trims leading hyphens" {
  result=$(output_slugify "---hello")
  [ "$result" = "hello" ]
}

@test "output_slugify: trims trailing hyphens" {
  result=$(output_slugify "hello---")
  [ "$result" = "hello" ]
}

@test "output_slugify: handles special chars in issue summaries" {
  result=$(output_slugify "Fix login bug (v2.0)")
  [ "$result" = "fix-login-bug-v2-0" ]
}

# --- output_build_issue_path ---

@test "output_build_issue_path: builds path with project key as directory" {
  result=$(output_build_issue_path "/tmp/export" "PROJ" "PROJ-1" "fix-login-bug" "md")
  [ "$result" = "/tmp/export/PROJ/PROJ-1-fix-login-bug.md" ]
}

@test "output_build_issue_path: uses correct extension for html format" {
  result=$(output_build_issue_path "/tmp/export" "PROJ" "PROJ-1" "fix-login-bug" "html")
  [ "$result" = "/tmp/export/PROJ/PROJ-1-fix-login-bug.html" ]
}

@test "output_build_issue_path: uses correct extension for raw format" {
  result=$(output_build_issue_path "/tmp/export" "PROJ" "PROJ-1" "fix-login-bug" "raw")
  [ "$result" = "/tmp/export/PROJ/PROJ-1-fix-login-bug.json" ]
}

@test "output_build_issue_path: handles multi-word project keys" {
  result=$(output_build_issue_path "/tmp/export" "MYPROJ" "MYPROJ-42" "add-dark-mode" "md")
  [ "$result" = "/tmp/export/MYPROJ/MYPROJ-42-add-dark-mode.md" ]
}

# --- output_write_file ---

@test "output_write_file: creates file at given path" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  [ -f "$_TMP_DIR/test.md" ]
}

@test "output_write_file: writes correct content" {
  output_write_file "$_TMP_DIR/test.md" "hello content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "hello content" ]
}

@test "output_write_file: creates intermediate directories" {
  output_write_file "$_TMP_DIR/deep/nested/dir/test.md" "content"
  [ -f "$_TMP_DIR/deep/nested/dir/test.md" ]
}

@test "output_write_file: does not overwrite existing file by default" {
  printf 'original' > "$_TMP_DIR/test.md"
  output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "original" ]
}

@test "output_write_file: overwrites existing file with JIRA_FORCE=1" {
  printf 'original' > "$_TMP_DIR/test.md"
  JIRA_FORCE=1 output_write_file "$_TMP_DIR/test.md" "new content"
  result=$(cat "$_TMP_DIR/test.md")
  [ "$result" = "new content" ]
}

# --- output_collision_path ---

@test "output_collision_path: appends issue ID when slug conflicts" {
  mkdir -p "$_TMP_DIR/PROJ"
  touch "$_TMP_DIR/PROJ/PROJ-1-fix-login-bug.md"

  result=$(output_collision_path "$_TMP_DIR/PROJ/PROJ-1-fix-login-bug.md" "10001")
  [ "$result" = "$_TMP_DIR/PROJ/PROJ-1-fix-login-bug--10001.md" ]
}

@test "output_collision_path: returns original path when no collision" {
  result=$(output_collision_path "$_TMP_DIR/PROJ/PROJ-2-new-issue.md" "10002")
  [ "$result" = "$_TMP_DIR/PROJ/PROJ-2-new-issue.md" ]
}

# --- output_project_key_from_issue_key ---

@test "output_project_key_from_issue_key: extracts project key from issue key" {
  result=$(output_project_key_from_issue_key "PROJ-123")
  [ "$result" = "PROJ" ]
}

@test "output_project_key_from_issue_key: handles multi-character project keys" {
  result=$(output_project_key_from_issue_key "MYPROJECT-42")
  [ "$result" = "MYPROJECT" ]
}
