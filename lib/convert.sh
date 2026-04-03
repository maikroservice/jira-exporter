#!/usr/bin/env bash
# lib/convert.sh - HTML to output format conversion and issue Markdown formatting

convert_to_html() {
  printf '%s' "$1"
}

convert_to_markdown() {
  local html="$1"
  if [ "${HAS_PANDOC:-0}" = "1" ]; then
    printf '%s' "$html" | pandoc -f html -t gfm --wrap=none 2>/dev/null
  else
    log_debug "pandoc unavailable — using built-in HTML→Markdown converter (degraded)"
    printf '%s' "$html" | _convert_builtin
  fi
}

# Built-in sed/awk HTML→Markdown converter
_convert_builtin() {
  sed 's/></>\n</g' | sed \
    -e 's|<h1[^>]*>\(.*\)</h1>|# \1|g' \
    -e 's|<h2[^>]*>\(.*\)</h2>|## \1|g' \
    -e 's|<h3[^>]*>\(.*\)</h3>|### \1|g' \
    -e 's|<h4[^>]*>\(.*\)</h4>|#### \1|g' \
    -e 's|<h5[^>]*>\(.*\)</h5>|##### \1|g' \
    -e 's|<h6[^>]*>\(.*\)</h6>|###### \1|g' \
    -e 's|<strong[^>]*>\(.*\)</strong>|**\1**|g' \
    -e 's|<b[^>]*>\(.*\)</b>|**\1**|g' \
    -e 's|<em[^>]*>\(.*\)</em>|*\1*|g' \
    -e 's|<i[^>]*>\(.*\)</i>|*\1*|g' \
    -e 's|<code[^>]*>\(.*\)</code>|`\1`|g' \
    -e 's|<a[^>]*href="\([^"]*\)"[^>]*>\(.*\)</a>|[\2](\1)|g' \
    -e "s|<a[^>]*href='\([^']*\)'[^>]*>\(.*\)</a>|[\2](\1)|g" \
    -e 's|<br[[:space:]]*/?>||g' \
    -e 's|<p[^>]*>||g' \
    -e 's|</p>||g' \
  | _convert_list_items \
  | _convert_pre_blocks \
  | _strip_remaining_tags \
  | _collapse_blank_lines
}

_convert_list_items() {
  awk '
    BEGIN { in_ol=0; counter=0 }
    /<ol[^>]*>/ { in_ol=1; counter=0; next }
    /<\/ol>/    { in_ol=0; print ""; next }
    /<ul[^>]*>/ { in_ol=0; next }
    /<\/ul>/    { print ""; next }
    /<li[^>]*>/ {
      sub(/<li[^>]*>/, "")
      sub(/<\/li>/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if (in_ol) {
        counter++
        print counter ". " $0
      } else {
        print "- " $0
      }
      next
    }
    /<\/li>/ { next }
    { print }
  '
}

_convert_pre_blocks() {
  awk '
    /<pre[^>]*>/ {
      in_pre=1
      line=$0
      sub(/<pre[^>]*>/, "", line)
      sub(/<code[^>]*>/, "", line)
      print "```"
      if (line !~ /^[[:space:]]*$/) print line
      next
    }
    /<\/pre>/ {
      in_pre=0
      line=$0
      sub(/<\/code>/, "", line)
      sub(/<\/pre>/, "", line)
      if (line !~ /^[[:space:]]*$/) print line
      print "```"
      next
    }
    in_pre {
      sub(/<code[^>]*>/, "")
      sub(/<\/code>/, "")
      print
      next
    }
    { print }
  '
}

_strip_remaining_tags() {
  sed 's/<[^>]*>//g'
}

_collapse_blank_lines() {
  awk '
    /^[[:space:]]*$/ { blank++; if (blank <= 2) print; next }
    { blank=0; print }
  '
}

# Format a Jira issue as a Markdown document
# Usage: format_issue_markdown <key> <summary> <status> <type> <priority>
#                              <assignee> <reporter> <labels> <created> <updated>
#                              <description_md> <comments>
# comments: newline-delimited records of "author|date|body_md" (empty = omit section)
format_issue_markdown() {
  local key="$1"
  local summary="$2"
  local status="$3"
  local type="$4"
  local priority="$5"
  local assignee="$6"
  local reporter="$7"
  local labels="$8"
  local created="$9"
  local updated="${10}"
  local description="${11}"
  local comments="${12}"

  # Truncate timestamps to date portion
  created="${created:0:10}"
  updated="${updated:0:10}"

  printf '# [%s] %s\n\n' "$key" "$summary"

  printf '| Field | Value |\n'
  printf '|-------|-------|\n'
  printf '| Status | %s |\n' "$status"
  printf '| Type | %s |\n' "$type"
  [ -n "$priority" ] && printf '| Priority | %s |\n' "$priority"
  [ -n "$assignee" ] && printf '| Assignee | %s |\n' "$assignee"
  [ -n "$reporter" ] && printf '| Reporter | %s |\n' "$reporter"
  [ -n "$labels" ]   && printf '| Labels | %s |\n' "$labels"
  [ -n "$created" ]  && printf '| Created | %s |\n' "$created"
  [ -n "$updated" ]  && printf '| Updated | %s |\n' "$updated"

  printf '\n## Description\n\n'
  if [ -n "$description" ]; then
    printf '%s\n' "$description"
  else
    printf '_No description provided._\n'
  fi

  if [ -n "$comments" ]; then
    printf '\n## Comments\n'
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local author date body
      author=$(printf '%s' "$line" | cut -d'|' -f1)
      date=$(printf '%s' "$line" | cut -d'|' -f2)
      body=$(printf '%s' "$line" | cut -d'|' -f3-)
      printf '\n### %s — %s\n\n%s\n' "$author" "$date" "$body"
    done <<< "$comments"
  fi
}
