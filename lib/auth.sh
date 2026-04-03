#!/usr/bin/env bash
# lib/auth.sh - Auth header construction for all credential schemes

# Returns the Authorization header value (not the header name)
auth_build_header() {
  case "${JIRA_AUTH_TYPE:-basic}" in
    bearer)
      if [ -z "${JIRA_TOKEN:-}" ]; then
        log_fatal "JIRA_TOKEN is required for bearer auth"
      fi
      printf 'Bearer %s' "${JIRA_TOKEN}"
      ;;
    basic)
      local credentials
      if [ "${JIRA_TYPE:-cloud}" = "cloud" ]; then
        if [ -z "${JIRA_EMAIL:-}" ] || [ -z "${JIRA_TOKEN:-}" ]; then
          log_fatal "JIRA_EMAIL and JIRA_TOKEN are required for Cloud basic auth"
        fi
        credentials="${JIRA_EMAIL}:${JIRA_TOKEN}"
      else
        local pass="${JIRA_TOKEN:-${JIRA_PASSWORD:-}}"
        if [ -z "${JIRA_USERNAME:-}" ] || [ -z "$pass" ]; then
          log_fatal "JIRA_USERNAME and JIRA_TOKEN (or JIRA_PASSWORD) are required for Server basic auth"
        fi
        credentials="${JIRA_USERNAME}:${pass}"
      fi
      local encoded
      encoded=$(printf '%s' "$credentials" | base64 | tr -d '\n')
      printf 'Basic %s' "$encoded"
      ;;
    *)
      log_fatal "Unknown JIRA_AUTH_TYPE: ${JIRA_AUTH_TYPE}"
      ;;
  esac
}

# Test API connectivity with a lightweight request
# Returns 0 on success, 1 on auth failure, 2 on other error
auth_test_connectivity() {
  local base_url="${JIRA_URL%/}"
  local auth_header
  auth_header=$(auth_build_header)

  local test_url="${base_url}/rest/api/3/myself"
  if [ "${JIRA_TYPE:-cloud}" = "server" ]; then
    test_url="${base_url}/rest/api/2/myself"
  fi

  log_debug "Testing connectivity: $test_url"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: ${auth_header}" \
    -H "Accept: application/json" \
    "${test_url}" 2>/dev/null)

  case "$http_code" in
    200) log_debug "Connectivity test passed (HTTP 200)"; return 0 ;;
    401|403) log_error "Authentication failed (HTTP ${http_code}). Check your credentials."; return 1 ;;
    000) log_error "Could not connect to ${base_url}. Check JIRA_URL."; return 2 ;;
    *) log_error "Unexpected HTTP ${http_code} from ${base_url}"; return 2 ;;
  esac
}
