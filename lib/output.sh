#!/usr/bin/env bash
# lib/output.sh - File writing, path building, and slug generation

# Convert a string to a filesystem-safe slug
# Usage: output_slugify <string>
output_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9-]/-/g' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//'
}

# Extract the project key from an issue key (e.g. "PROJ-123" -> "PROJ")
# Usage: output_project_key_from_issue_key <issue_key>
output_project_key_from_issue_key() {
  printf '%s' "$1" | sed 's/-[0-9]*$//'
}

# Build the full output path for an issue
# Usage: output_build_issue_path <output_dir> <project_key> <issue_key> <summary_slug> <format>
output_build_issue_path() {
  local out_dir="$1"
  local project_key="$2"
  local issue_key="$3"
  local summary_slug="$4"
  local format="$5"

  local ext
  case "$format" in
    md)   ext="md"   ;;
    html) ext="html" ;;
    raw)  ext="json" ;;
    *)    ext="md"   ;;
  esac

  printf '%s/%s/%s-%s.%s' "$out_dir" "$project_key" "$issue_key" "$summary_slug" "$ext"
}

# Return a collision-free path: if the path exists, append --<issue_id> before extension
# Usage: output_collision_path <path> <issue_id>
output_collision_path() {
  local path="$1"
  local issue_id="$2"

  if [ ! -e "$path" ]; then
    printf '%s' "$path"
    return 0
  fi

  local dir base ext
  dir=$(dirname "$path")
  base=$(basename "$path")
  ext="${base##*.}"
  base="${base%.*}"

  printf '%s/%s--%s.%s' "$dir" "$base" "$issue_id" "$ext"
}

# Write content to a file, creating intermediate directories as needed
# Respects JIRA_FORCE=1 to allow overwriting
# Usage: output_write_file <path> <content>
output_write_file() {
  local path="$1"
  local content="$2"

  if [ -e "$path" ] && [ "${JIRA_FORCE:-0}" != "1" ]; then
    log_warn "Skipping existing file (use --force to overwrite): $path"
    return 0
  fi

  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir" || { log_error "Could not create directory: $dir"; return 1; }

  local tmp
  tmp=$(mktemp "${dir}/.tmp_XXXXXX")
  printf '%s' "$content" > "$tmp" && mv "$tmp" "$path" || {
    rm -f "$tmp"
    log_error "Could not write file: $path"
    return 1
  }

  log_debug "Wrote: $path"
}
