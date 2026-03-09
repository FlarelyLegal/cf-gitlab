#!/usr/bin/env bats
# Unit tests for stacks/caddy/entrypoint.sh
# Runs the entrypoint with stub commands to verify env var handling and cron setup.

load test_helper

ENTRYPOINT="${BATS_TEST_DIRNAME}/../../stacks/caddy/entrypoint.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
  STUB_DIR="${TEST_DIR}/stubs"
  mkdir -p "$STUB_DIR"

  # Stub: crontab -- capture the cron schedule written to it
  cat >"${STUB_DIR}/crontab" <<'STUB'
#!/bin/sh
cat > "${TEST_DIR}/crontab-input"
STUB
  chmod +x "${STUB_DIR}/crontab"

  # Stub: crond -- no-op
  cat >"${STUB_DIR}/crond" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "${STUB_DIR}/crond"

  # Stub: command passed to exec "$@" -- just capture and exit
  cat >"${STUB_DIR}/caddy" <<'STUB'
#!/bin/sh
exit 0
STUB
  chmod +x "${STUB_DIR}/caddy"

  export TEST_DIR
  export PATH="${STUB_DIR}:${PATH}"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ─── CADDY_ADMIN binding ────────────────────────────────────────────────────

@test "CADDY_API_ENABLED=false binds admin to localhost" {
  export CADDY_API_ENABLED=false
  run "$ENTRYPOINT" caddy docker-proxy
  assert_success
  # CADDY_ADMIN should be localhost:2019 (default)
  # We can verify by checking the env was exported -- re-run in subshell
  result=$(CADDY_API_ENABLED=false sh -c '. '"$ENTRYPOINT"' true 2>/dev/null; printf "%s" "$CADDY_ADMIN"' 2>/dev/null || true)
  assert_equal "$result" "localhost:2019"
}

@test "CADDY_API_ENABLED=true binds admin to 0.0.0.0" {
  result=$(CADDY_API_ENABLED=true sh -c '. '"$ENTRYPOINT"' true 2>/dev/null; printf "%s" "$CADDY_ADMIN"' 2>/dev/null || true)
  assert_equal "$result" "0.0.0.0:2019"
}

@test "CADDY_API_ENABLED unset defaults to localhost" {
  unset CADDY_API_ENABLED
  result=$(sh -c '. '"$ENTRYPOINT"' true 2>/dev/null; printf "%s" "$CADDY_ADMIN"' 2>/dev/null || true)
  assert_equal "$result" "localhost:2019"
}

# ─── Cron setup ──────────────────────────────────────────────────────────────

@test "installs certbot renewal crontab" {
  run "$ENTRYPOINT" caddy docker-proxy
  assert_success
  # Verify the crontab stub captured input containing certbot renew
  run cat "${TEST_DIR}/crontab-input"
  assert_output --partial "certbot renew"
}

@test "cron schedule runs twice daily" {
  run "$ENTRYPOINT" caddy docker-proxy
  assert_success
  run cat "${TEST_DIR}/crontab-input"
  assert_output --partial "3,15"
}

# ─── exec passthrough ───────────────────────────────────────────────────────

@test "passes arguments to exec" {
  run "$ENTRYPOINT" caddy docker-proxy
  assert_success
}
