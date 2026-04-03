#!/usr/bin/env bash
# lib/config.sh - Configuration loading
# Precedence (highest to lowest): CLI flags > env vars > .jirarc > .env > defaults

config_load() {
  # 1. .jirarc (project dir or home dir) — highest file-based priority
  local rc_file=""
  if [ -f "./.jirarc" ]; then
    rc_file="./.jirarc"
  elif [ -f "${HOME}/.jirarc" ]; then
    rc_file="${HOME}/.jirarc"
  fi
  if [ -n "$rc_file" ]; then
    log_debug "Loading config from $rc_file"
    _config_parse_file "$rc_file"
  fi

  # 2. .env (project dir only) — lowest file-based priority
  if [ -f "./.env" ]; then
    log_debug "Loading config from .env"
    _config_parse_file "./.env"
  fi

  # Apply defaults for anything still unset
  : "${JIRA_TYPE:=cloud}"
  : "${JIRA_FORMAT:=md}"
  : "${JIRA_OUTPUT_DIR:=./export}"
  : "${JIRA_MAX_RETRIES:=3}"
  : "${JIRA_RETRY_DELAY:=5}"
  : "${JIRA_DEBUG:=0}"
  : "${JIRA_AUTH_TYPE:=basic}"
  : "${JIRA_SEARCH_PAGE_SIZE:=50}"

  # Derive auth type: if only a token is set (no email/username), use bearer
  if [ "${JIRA_AUTH_TYPE}" = "basic" ]; then
    if [ -n "${JIRA_TOKEN:-}" ] && [ -z "${JIRA_USERNAME:-}" ] && [ -z "${JIRA_EMAIL:-}" ]; then
      JIRA_AUTH_TYPE="bearer"
    fi
  fi

  export JIRA_URL JIRA_TYPE JIRA_USERNAME JIRA_EMAIL
  export JIRA_TOKEN JIRA_PASSWORD JIRA_AUTH_TYPE
  export JIRA_OUTPUT_DIR JIRA_FORMAT
  export JIRA_MAX_RETRIES JIRA_RETRY_DELAY JIRA_DEBUG
  export JIRA_SEARCH_PAGE_SIZE

  log_debug "Config loaded: type=${JIRA_TYPE} format=${JIRA_FORMAT} output=${JIRA_OUTPUT_DIR}"
}

# Parse a KEY=VALUE file. Only processes JIRA_* keys.
# Does not overwrite vars already set in the environment.
_config_parse_file() {
  local file="$1"
  local line key value
  while IFS= read -r line; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
    case "$line" in
      \#*|"") continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=$(printf '%s' "$key" | sed 's/[[:space:]]//g')
    case "$key" in
      JIRA_*) ;;
      *) continue ;;
    esac
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*#.*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed "s/^['\"]//;s/['\"]$//")
    if [ -z "${!key:-}" ]; then
      export "$key"="$value"
    fi
  done < "$file"
}

config_require() {
  local var="$1"
  local hint="${2:-Set $var in .jirarc or as an environment variable}"
  if [ -z "${!var:-}" ]; then
    log_fatal "$var is required but not set. $hint"
  fi
}

config_require_api() {
  config_require JIRA_URL "Set JIRA_URL to your Jira base URL (e.g. https://yoursite.atlassian.net)"
  case "${JIRA_AUTH_TYPE}" in
    bearer)
      config_require JIRA_TOKEN "Set JIRA_TOKEN to your API token or PAT"
      ;;
    basic)
      if [ "${JIRA_TYPE}" = "cloud" ]; then
        config_require JIRA_EMAIL "Set JIRA_EMAIL to your Atlassian account email"
        config_require JIRA_TOKEN "Set JIRA_TOKEN to your Atlassian API token"
      else
        config_require JIRA_USERNAME "Set JIRA_USERNAME for Server/DC auth"
        if [ -z "${JIRA_TOKEN:-}" ] && [ -z "${JIRA_PASSWORD:-}" ]; then
          log_fatal "Either JIRA_TOKEN or JIRA_PASSWORD is required for Server/DC basic auth"
        fi
      fi
      ;;
    *)
      log_fatal "Unknown JIRA_AUTH_TYPE: ${JIRA_AUTH_TYPE}. Use 'basic' or 'bearer'."
      ;;
  esac
}
