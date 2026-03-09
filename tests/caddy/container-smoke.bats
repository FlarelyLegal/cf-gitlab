#!/usr/bin/env bats
# Integration tests -- build and run the custom Caddy container.
# Requires Docker to be available.

load test_helper

CONTAINER_NAME="caddy-test-$$"
IMAGE_NAME="${CADDY_TEST_IMAGE:-caddy-test:bats}"
PROJECT_ROOT="${BATS_TEST_DIRNAME}/../../stacks/caddy"
DOCKER_SOCK="/var/run/docker.sock"

setup_file() {
  # Skip build if image was pre-built by CI (CADDY_TEST_IMAGE is set)
  if [ -z "${CADDY_TEST_IMAGE:-}" ]; then
    docker build -t "$IMAGE_NAME" "$PROJECT_ROOT"
  fi
}

teardown_file() {
  docker rmi "$IMAGE_NAME" --force 2>/dev/null || true
}

setup() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

teardown() {
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}

# ─── Basic container lifecycle ───────────────────────────────────────────────

@test "container starts successfully" {
  run docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  assert_success
  sleep 3
  run docker inspect --format='{{.State.Running}}' "$CONTAINER_NAME"
  assert_output "true"
}

# ─── Caddy binary ───────────────────────────────────────────────────────────

@test "caddy binary is present and runs" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" caddy version
  assert_success
}

@test "caddy has cloudflare dns plugin" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" caddy list-modules
  assert_success
  assert_output --partial "dns.providers.cloudflare"
}

@test "caddy has docker proxy plugin" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" caddy list-modules
  assert_success
  assert_output --partial "docker_proxy"
}

# ─── Certbot ─────────────────────────────────────────────────────────────────

@test "certbot is installed" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" certbot --version
  assert_success
}

@test "certbot cloudflare plugin is installed" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" certbot plugins
  assert_success
  assert_output --partial "dns-cloudflare"
}

# ─── Cron ────────────────────────────────────────────────────────────────────

@test "cron is running with certbot renewal schedule" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    "$IMAGE_NAME"
  sleep 3
  run docker exec "$CONTAINER_NAME" crontab -l
  assert_success
  assert_output --partial "certbot renew"
  assert_output --partial "3,15"
}

# ─── Admin API ───────────────────────────────────────────────────────────────

@test "CADDY_API_ENABLED=true binds admin API to 0.0.0.0" {
  docker run -d --name "$CONTAINER_NAME" \
    -v "$DOCKER_SOCK:$DOCKER_SOCK:ro" \
    -e CADDY_API_ENABLED=true \
    -p 0:2019 \
    "$IMAGE_NAME"
  sleep 3
  port=$(docker port "$CONTAINER_NAME" 2019 | head -1 | cut -d: -f2)
  run curl -sf "http://127.0.0.1:${port}/config/"
  assert_success
}
