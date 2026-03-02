#!/usr/bin/env bash
set -euo pipefail

# ─── Flags ────────────────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'rm -f /tmp/create-runner.rb /tmp/runner-output.txt /tmp/runner-repo.sh 2>/dev/null; printf "\n"; printf "%s\n" "✗ Runner install failed at line ${LINENO}. Check output above."' ERR

# ─── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f /root/.secrets/gitlab.env ]]; then
  printf '%s\n' "✗ Missing /root/.secrets/gitlab.env — run deploy.sh first."
  exit 1
fi
set -a
# shellcheck source=/dev/null
source /root/.secrets/gitlab.env
set +a
printf '%s\n' "✓ Config loaded"

if ${DRY_RUN}; then
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  GitLab URL:   https://${GITLAB_DOMAIN}"
  printf '%s\n' "  Runner name:  ${RUNNER_NAME}"
  printf '%s\n' "  Runner tags:  ${RUNNER_TAGS}"
  printf '%s\n' "  Executor:     shell"
  printf '\n'
  printf '%s\n' "  Would perform:"
  printf '%s\n' "    1. Add GitLab Runner APT repository"
  printf '%s\n' "    2. Install gitlab-runner + helper images"
  printf '%s\n' "    3. Create runner token via Rails console"
  printf '%s\n' "    4. Register runner (shell executor)"
  printf '%s\n' "    5. Start + verify runner service"
  printf '%s\n' "    6. Clean up temp files"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to execute."
  exit 0
fi

# ─── Step 1: Add GitLab Runner repository ────────────────────────────────────
printf '%s\n' "→ Downloading runner repo script..."
curl -fsSL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" -o /tmp/runner-repo.sh
printf '%s\n' "✓ Repo script downloaded"

printf '%s\n' "→ Adding runner APT repository..."
bash /tmp/runner-repo.sh
printf '%s\n' "✓ Runner repo added"

# ─── Step 2: Install GitLab Runner ───────────────────────────────────────────
printf '%s\n' "→ Installing gitlab-runner..."
apt-get install -y gitlab-runner
printf '%s\n' "✓ gitlab-runner installed"

printf '%s\n' "→ Installing gitlab-runner-helper-images..."
if apt-get install -y gitlab-runner-helper-images 2>/dev/null; then
  printf '%s\n' "✓ Helper images installed"
else
  printf '%s\n' "⚠ Helper images package not available (runner will download them on demand)"
fi

# ─── Step 3: Create runner token via Rails console ──────────────────────────
# ⚠ DEPRECATION WARNING:
# This uses the legacy Ci::Runner.create! method (runner.token).
# GitLab 16.0 deprecated registration tokens in favor of the glrt- auth token
# flow (POST /api/v4/user/runners). GitLab 17.0 removed the old registration
# token endpoint. The Rails console method still works but may be removed in
# GitLab 18+. To future-proof, migrate to the new runner creation API:
#   POST https://${GITLAB_DOMAIN}/api/v4/user/runners
#   with runner_type=instance_type, description, tag_list
#   Returns a { token: "glrt-..." } for gitlab-runner register.

# Check if a runner with this name already exists (idempotency)
printf '%s\n' "→ Checking for existing runner named '${RUNNER_NAME}'..."
EXISTING_RUNNER=$(gitlab-rails runner "r = Ci::Runner.find_by(description: '${RUNNER_NAME}'); puts r&.id" 2>/dev/null || printf '')
if [[ -n "${EXISTING_RUNNER}" && "${EXISTING_RUNNER}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "✓ Runner '${RUNNER_NAME}' already exists (ID: ${EXISTING_RUNNER}) — skipping creation"
  printf '\n'
  printf '%s\n' "  To re-register, first delete via Admin → Runners or:"
  printf '%s\n' "    gitlab-rails runner \"Ci::Runner.find(${EXISTING_RUNNER}).destroy!\""
  trap - ERR
  exit 0
fi

printf '%s\n' "→ Creating runner token via Rails console (this takes ~45s to load)..."
cat >/tmp/create-runner.rb <<'RUBY'
runner = Ci::Runner.create!(
  runner_type: :instance_type,
  description: ENV.fetch("GL_RUNNER_NAME"),
  active: true,
  run_untagged: true,
  tag_list: ENV.fetch("GL_RUNNER_TAGS").split(",")
)
puts "TOKEN=#{runner.token}"
puts "ID=#{runner.id}"
RUBY

GL_RUNNER_NAME="${RUNNER_NAME}" GL_RUNNER_TAGS="${RUNNER_TAGS}" gitlab-rails runner /tmp/create-runner.rb >/tmp/runner-output.txt 2>&1
RUNNER_TOKEN="$(grep '^TOKEN=' /tmp/runner-output.txt | cut -d= -f2)"
RUNNER_ID="$(grep '^ID=' /tmp/runner-output.txt | cut -d= -f2)"

if [[ -z "${RUNNER_TOKEN}" ]]; then
  printf '%s\n' "✗ Failed to create runner token. Rails output:"
  cat /tmp/runner-output.txt
  exit 1
fi
printf '%s\n' "✓ Runner token created (ID: ${RUNNER_ID})"

# ─── Step 4: Register the runner ────────────────────────────────────────────
printf '%s\n' "→ Registering runner with GitLab..."
gitlab-runner register \
  --non-interactive \
  --url "https://${GITLAB_DOMAIN}" \
  --token "${RUNNER_TOKEN}" \
  --executor shell \
  --description "${RUNNER_NAME}" \
  --tag-list "${RUNNER_TAGS}"
printf '%s\n' "✓ Runner registered"

# ─── Step 5: Start + verify ─────────────────────────────────────────────────
printf '%s\n' "→ Starting runner service..."
gitlab-runner start 2>/dev/null || true
gitlab-runner verify
printf '%s\n' "✓ Runner is alive"

printf '\n'
printf '%s\n' "→ Runner version:"
gitlab-runner --version

# ─── Step 6: Clean up temp files ──────────────────────────────────────────────
rm -f /tmp/create-runner.rb /tmp/runner-output.txt /tmp/runner-repo.sh
printf '%s\n' "✓ Temp files cleaned up"

# ─── Done ─────────────────────────────────────────────────────────────────────
trap - ERR
printf '\n'
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  GitLab Runner registered and running"
printf '%s\n' "  Name:     ${RUNNER_NAME}"
printf '%s\n' "  Executor: shell"
printf '%s\n' "  Tags:     ${RUNNER_TAGS}"
printf '%s\n' "  Config:   /etc/gitlab-runner/config.toml"
printf '%s\n' "  Admin:    https://${GITLAB_DOMAIN}/admin/runners"
printf '%s\n' "════════════════════════════════════════════════════"
