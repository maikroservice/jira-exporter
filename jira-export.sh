#!/usr/bin/env bash
# jira-export.sh - Export Jira issues to Markdown, HTML, or raw JSON
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source all library modules
for _lib in log deps config auth api convert output; do
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/lib/${_lib}.sh"
done

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Export Jira issues to Markdown, HTML, or raw JSON.

Scope (optional — defaults to discovering all accessible boards):
  --issue <key|url>      Export a single issue
  --project <KEY>        Export all issues in a project
  --board <ID>           Export all issues from a board
  --jql <query>          Export issues matching a JQL query
  (none)                 Discover all boards and export their issues

Format:
  --format md|html|raw   Output format (default: md)

Output:
  --output <dir>         Output directory (default: ./export)
  --force                Overwrite existing files

Options:
  --comments             Include issue comments in output
  --list                 Dry run: print what would be exported, no files written
  --debug                Enable verbose debug output
  --help                 Show this help

Authentication (via env vars or .jirarc):
  JIRA_URL               Base URL (e.g. https://yoursite.atlassian.net)
  JIRA_TYPE              cloud (default) or server
  JIRA_AUTH_TYPE         basic (default) or bearer
  JIRA_EMAIL             Atlassian account email (Cloud basic auth)
  JIRA_TOKEN             API token (Cloud) or PAT (Server bearer)
  JIRA_USERNAME          Username (Server basic auth)
  JIRA_PASSWORD          Password (Server basic auth, if not using token)
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SCOPE=""
SCOPE_TARGET=""
FORMAT=""
OUTPUT_DIR=""
FORCE=0
LIST_ONLY=0
INCLUDE_COMMENTS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)    SCOPE=issue;   SCOPE_TARGET="$2"; shift 2 ;;
    --project)  SCOPE=project; SCOPE_TARGET="$2"; shift 2 ;;
    --board)    SCOPE=board;   SCOPE_TARGET="$2"; shift 2 ;;
    --jql)      SCOPE=jql;     SCOPE_TARGET="$2"; shift 2 ;;
    --format)   FORMAT="$2";   shift 2 ;;
    --output)   OUTPUT_DIR="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --list)     LIST_ONLY=1; shift ;;
    --comments) INCLUDE_COMMENTS=1; shift ;;
    --debug)    export JIRA_DEBUG=1; shift ;;
    --help|-h)  usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

[ -z "$SCOPE" ] && SCOPE=discover

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
deps_check
config_load

# CLI flags override config
[ -n "$FORMAT" ]     && export JIRA_FORMAT="$FORMAT"
[ -n "$OUTPUT_DIR" ] && export JIRA_OUTPUT_DIR="$OUTPUT_DIR"
[ "$FORCE" = "1" ]   && export JIRA_FORCE=1

: "${JIRA_FORMAT:=md}"
: "${JIRA_OUTPUT_DIR:=./export}"

config_require_api
if ! auth_test_connectivity; then
  exit 1
fi

log_debug "scope=${SCOPE} format=${JIRA_FORMAT} output=${JIRA_OUTPUT_DIR} comments=${INCLUDE_COMMENTS}"

# ---------------------------------------------------------------------------
# Export a single issue
# ---------------------------------------------------------------------------
_export_issue() {
  local issue_json="$1"

  local key summary status type priority assignee reporter labels created updated
  key=$(api_extract_key "$issue_json")
  summary=$(api_extract_summary "$issue_json")
  status=$(api_extract_status "$issue_json")
  type=$(api_extract_type "$issue_json")
  priority=$(api_extract_priority "$issue_json")
  assignee=$(api_extract_assignee "$issue_json")
  reporter=$(api_extract_reporter "$issue_json")
  labels=$(api_extract_labels "$issue_json")
  created=$(api_extract_created "$issue_json")
  updated=$(api_extract_updated "$issue_json")

  if [ "$LIST_ONLY" = "1" ]; then
    printf '[%s] %s\n' "$key" "$summary"
    return 0
  fi

  local content
  case "$JIRA_FORMAT" in
    md)
      local desc_html desc_md
      desc_html=$(api_extract_description_html "$issue_json")
      desc_md=$(convert_to_markdown "$desc_html")

      local comments_str=""
      if [ "$INCLUDE_COMMENTS" = "1" ]; then
        comments_str=$(_build_comments_str "$issue_json")
      fi

      content=$(format_issue_markdown \
        "$key" "$summary" "$status" "$type" "$priority" \
        "$assignee" "$reporter" "$labels" "$created" "$updated" \
        "$desc_md" "$comments_str")
      ;;
    html)
      local desc_html
      desc_html=$(api_extract_description_html "$issue_json")
      content="$desc_html"
      ;;
    raw)
      content="$issue_json"
      ;;
  esac

  local project_key slug path
  project_key=$(output_project_key_from_issue_key "$key")
  slug=$(output_slugify "$summary")
  path=$(output_build_issue_path "$JIRA_OUTPUT_DIR" "$project_key" "$key" "$slug" "$JIRA_FORMAT")
  if [ "${JIRA_FORCE:-0}" != "1" ]; then
    local issue_id
    issue_id=$(api_extract_id "$issue_json")
    path=$(output_collision_path "$path" "$issue_id")
  fi
  output_write_file "$path" "$content"
  log_info "Exported: $key $summary → $path"
}

# Build a comments string from rendered fields: "author|date|body_md\nauthor|date|body_md\n..."
_build_comments_str() {
  local issue_json="$1"
  [ "${HAS_JQ:-0}" = "1" ] || return 0

  local raw_comments
  raw_comments=$(api_extract_comments_raw "$issue_json")
  [ -z "$raw_comments" ] && return 0

  local result=""
  while IFS=$'\t' read -r author date body_html; do
    [ -z "$author" ] && continue
    local body_md
    body_md=$(convert_to_markdown "$body_html")
    # Use | as delimiter; replace any | in body with a space to avoid parsing issues
    body_md=$(printf '%s' "$body_md" | tr '|' ' ')
    local record="${author}|${date}|${body_md}"
    if [ -n "$result" ]; then
      result="${result}
${record}"
    else
      result="$record"
    fi
  done <<< "$raw_comments"

  printf '%s' "$result"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "$SCOPE" in

  discover)
    boards_file=$(mktemp)
    api_get_all_boards "$boards_file" || { rm -f "$boards_file"; exit 1; }

    if [ ! -s "$boards_file" ]; then
      log_info "No accessible boards found."
      rm -f "$boards_file"
      exit 0
    fi

    while IFS= read -r board_json; do
      [ -z "$board_json" ] && continue
      board_id=$(api_extract_board_id "$board_json")
      board_name=$(api_extract_board_name "$board_json")
      [ -z "$board_id" ] || [ "$board_id" = "null" ] && continue

      if [ "$LIST_ONLY" = "1" ]; then
        printf '[board %s] %s\n' "$board_id" "$board_name"
        continue
      fi

      log_info "Exporting board: $board_name (id=$board_id)"
      issues_file=$(mktemp)
      api_get_board_issues "$board_id" "$issues_file" || { rm -f "$issues_file"; continue; }

      while IFS= read -r issue_json; do
        [ -z "$issue_json" ] && continue
        _export_issue "$issue_json"
      done < "$issues_file"
      rm -f "$issues_file"
    done < "$boards_file"
    rm -f "$boards_file"
    ;;

  issue)
    issue_key=$(api_url_to_key "$SCOPE_TARGET") || exit 1
    issue_json=$(api_get_issue "$issue_key") || exit 1
    _export_issue "$issue_json"
    ;;

  project)
    local_jql="project+%3D+${SCOPE_TARGET}"
    issues_file=$(mktemp)
    api_search_issues "$local_jql" "$issues_file" || { rm -f "$issues_file"; exit 1; }

    while IFS= read -r issue_json; do
      [ -z "$issue_json" ] && continue
      _export_issue "$issue_json"
    done < "$issues_file"
    rm -f "$issues_file"
    ;;

  board)
    issues_file=$(mktemp)
    api_get_board_issues "$SCOPE_TARGET" "$issues_file" || { rm -f "$issues_file"; exit 1; }

    while IFS= read -r issue_json; do
      [ -z "$issue_json" ] && continue
      _export_issue "$issue_json"
    done < "$issues_file"
    rm -f "$issues_file"
    ;;

  jql)
    local_jql=$(printf '%s' "$SCOPE_TARGET" | sed 's/"/%22/g')
    issues_file=$(mktemp)
    api_search_issues "$local_jql" "$issues_file" || { rm -f "$issues_file"; exit 1; }

    while IFS= read -r issue_json; do
      [ -z "$issue_json" ] && continue
      _export_issue "$issue_json"
    done < "$issues_file"
    rm -f "$issues_file"
    ;;

esac
