#!/usr/bin/env bats
# tests/unit/test_auth.bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  source "$REPO_ROOT/lib/log.sh"
  source "$REPO_ROOT/lib/deps.sh"
  source "$REPO_ROOT/lib/auth.sh"
  unset JIRA_URL JIRA_TYPE JIRA_AUTH_TYPE
  unset JIRA_EMAIL JIRA_TOKEN JIRA_USERNAME JIRA_PASSWORD
}

# --- Cloud basic auth ---

@test "auth_build_header: Cloud basic auth encodes email:token as Base64" {
  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_EMAIL=user@example.com
  export JIRA_TOKEN=myapitoken

  result=$(auth_build_header)
  expected="Basic $(printf 'user@example.com:myapitoken' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Cloud basic auth header has no newlines" {
  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_EMAIL=user@example.com
  export JIRA_TOKEN=myapitoken

  result=$(auth_build_header)
  [[ "$result" != *$'\n'* ]]
}

@test "auth_build_header: Cloud basic auth exits non-zero when EMAIL missing" {
  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_TOKEN=myapitoken
  unset JIRA_EMAIL

  run auth_build_header
  [ "$status" -ne 0 ]
}

@test "auth_build_header: Cloud basic auth exits non-zero when TOKEN missing" {
  export JIRA_TYPE=cloud
  export JIRA_AUTH_TYPE=basic
  export JIRA_EMAIL=user@example.com
  unset JIRA_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Server basic auth ---

@test "auth_build_header: Server basic auth encodes username:password" {
  export JIRA_TYPE=server
  export JIRA_AUTH_TYPE=basic
  export JIRA_USERNAME=admin
  export JIRA_PASSWORD=secret

  result=$(auth_build_header)
  expected="Basic $(printf 'admin:secret' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Server basic auth uses TOKEN as password when set" {
  export JIRA_TYPE=server
  export JIRA_AUTH_TYPE=basic
  export JIRA_USERNAME=admin
  export JIRA_TOKEN=pat_token
  unset JIRA_PASSWORD

  result=$(auth_build_header)
  expected="Basic $(printf 'admin:pat_token' | base64 | tr -d '\n')"
  [ "$result" = "$expected" ]
}

@test "auth_build_header: Server basic auth exits non-zero when USERNAME missing" {
  export JIRA_TYPE=server
  export JIRA_AUTH_TYPE=basic
  export JIRA_PASSWORD=secret
  unset JIRA_USERNAME

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Bearer auth ---

@test "auth_build_header: bearer auth returns Bearer <token>" {
  export JIRA_AUTH_TYPE=bearer
  export JIRA_TOKEN=my_pat_token

  result=$(auth_build_header)
  [ "$result" = "Bearer my_pat_token" ]
}

@test "auth_build_header: bearer auth exits non-zero when TOKEN missing" {
  export JIRA_AUTH_TYPE=bearer
  unset JIRA_TOKEN

  run auth_build_header
  [ "$status" -ne 0 ]
}

# --- Unknown auth type ---

@test "auth_build_header: exits non-zero for unknown auth type" {
  export JIRA_AUTH_TYPE=oauth2
  export JIRA_TOKEN=something

  run auth_build_header
  [ "$status" -ne 0 ]
}
