#!/usr/bin/env bash
set -euo pipefail

# ─── External GitLab Runner Setup ────────────────────────────────────────────
# Runs on a dedicated runner LXC (not the GitLab server). Installs and
# registers a GitLab Runner via API, sets up UFW, and installs all CI tools
# from runner-apps.json.
#
# Requires /root/.secrets/runner.env with:
#   GITLAB_DOMAIN, GITLAB_PAT, RUNNER_NAME, RUNNER_TAGS, SSH_ALLOW_CIDR,
#   ORG_NAME, ORG_URL
#
# Usage:
#   bash external-runner.sh              # full install
#   bash external-runner.sh --dry-run    # preview changes
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  printf '%s\n' "── DRY RUN (no changes will be made) ──"
  printf '\n'
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ External runner setup failed at line ${LINENO}. Check output above."' ERR

# ─── Load config ──────────────────────────────────────────────────────────────
if [[ ! -f /root/.secrets/runner.env ]]; then
  printf '%s\n' "✗ Missing /root/.secrets/runner.env"
  exit 1
fi
set -a
# shellcheck source=/dev/null
source /root/.secrets/runner.env
set +a
printf '%s\n' "✓ Config loaded"

# ─── Validate required variables ──────────────────────────────────────────────
for var in GITLAB_DOMAIN GITLAB_PAT RUNNER_NAME RUNNER_TAGS SSH_ALLOW_CIDR ORG_NAME ORG_URL; do
  if [[ -z "${!var:-}" ]]; then
    printf '%s\n' "✗ Missing ${var} in runner.env"
    exit 1
  fi
done

if ${DRY_RUN}; then
  printf '%s\n' "── Dry run summary ──"
  printf '%s\n' "  GitLab URL:    https://${GITLAB_DOMAIN}"
  printf '%s\n' "  Runner name:   ${RUNNER_NAME}"
  printf '%s\n' "  Runner tags:   ${RUNNER_TAGS}"
  printf '%s\n' "  Executor:      shell"
  printf '%s\n' "  SSH allow:     ${SSH_ALLOW_CIDR}"
  printf '%s\n' "  PAT:           ${GITLAB_PAT:0:8}...(redacted)"
  printf '\n'
  printf '%s\n' "  Would perform:"
  printf '%s\n' "    1. Set MOTD (banner + runner info)"
  printf '%s\n' "    2. Configure UFW (default deny, SSH from ${SSH_ALLOW_CIDR}, 80, 443)"
  printf '%s\n' "    3. Add GitLab Runner APT repository"
  printf '%s\n' "    4. Install gitlab-runner + helper images"
  printf '%s\n' "    5. Create runner token via GitLab API"
  printf '%s\n' "    6. Register runner (shell executor)"
  printf '%s\n' "    7. Start + verify runner service"
  printf '%s\n' "    8. Install CI tools from runner-apps.json"
  printf '\n'
  printf '%s\n' "✓ Dry run passed. Run without --dry-run to execute."
  exit 0
fi

# ─── Step 1: MOTD ────────────────────────────────────────────────────────────
printf '%s\n' "→ Setting MOTD..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f /tmp/runner-banner.txt ]]; then
  ASCII_BANNER="$(cat /tmp/runner-banner.txt)"
elif [[ -f "${SCRIPT_DIR}/banner.txt" ]]; then
  ASCII_BANNER="$(cat "${SCRIPT_DIR}/banner.txt")"
else
  ASCII_BANNER="GITLAB RUNNER"
fi

LXC_IP="$(hostname -I | awk '{print $1}')"
LXC_HOSTNAME="$(hostname)"
# shellcheck source=/dev/null
LXC_OS="$(. /etc/os-release && printf '%s' "${PRETTY_NAME}")"

printf '%s\n' "
${ASCII_BANNER}

  GitLab Runner (External)
  GitLab:        https://${GITLAB_DOMAIN}
  Organization:  ${ORG_NAME} — ${ORG_URL}
  Runner:        ${RUNNER_NAME} (${RUNNER_TAGS})
  Hostname:      ${LXC_HOSTNAME}
  IP Address:    ${LXC_IP}
  OS:            ${LXC_OS}
" >/etc/motd
printf '%s\n' "✓ MOTD set"

# ─── Step 2: UFW ─────────────────────────────────────────────────────────────
printf '%s\n' "→ Configuring UFW..."
apt-get update -qq
apt-get install -y -qq ufw >/dev/null

ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow from "${SSH_ALLOW_CIDR}" to any port 22 proto tcp >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
printf '%s\n' "✓ UFW enabled (SSH from ${SSH_ALLOW_CIDR}, default deny incoming)"

# ─── Step 3: Add GitLab Runner repository ────────────────────────────────────
printf '%s\n' "→ Adding GitLab Runner APT repository..."
curl -fsSL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" -o /tmp/runner-repo.sh
bash /tmp/runner-repo.sh
rm -f /tmp/runner-repo.sh
printf '%s\n' "✓ Runner repo added"

# ─── Step 4: Install GitLab Runner ───────────────────────────────────────────
printf '%s\n' "→ Installing gitlab-runner..."
apt-get install -y gitlab-runner
printf '%s\n' "✓ gitlab-runner installed"

printf '%s\n' "→ Installing gitlab-runner-helper-images..."
if apt-get install -y gitlab-runner-helper-images 2>/dev/null; then
  printf '%s\n' "✓ Helper images installed"
else
  printf '%s\n' "⚠ Helper images package not available (runner will download them on demand)"
fi

# ─── Step 5: Create runner token via GitLab API ─────────────────────────────
printf '%s\n' "→ Creating runner token via GitLab API..."

# Check if a runner with this name already exists
EXISTING_ID=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
  "https://${GITLAB_DOMAIN}/api/v4/runners/all?type=instance_type&per_page=100" \
  | jq -r ".[] | select(.description == \"${RUNNER_NAME}\") | .id" 2>/dev/null || printf '')

if [[ -n "${EXISTING_ID}" && "${EXISTING_ID}" =~ ^[0-9]+$ ]]; then
  printf '%s\n' "✓ Runner '${RUNNER_NAME}' already exists (ID: ${EXISTING_ID}) — skipping creation"
  # Get existing runner's token by re-registering
  printf '%s\n' "→ Fetching existing runner authentication token..."
  RUNNER_TOKEN=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
    "https://${GITLAB_DOMAIN}/api/v4/runners/${EXISTING_ID}" \
    | jq -r '.token // empty' 2>/dev/null || printf '')
  if [[ -z "${RUNNER_TOKEN}" ]]; then
    printf '%s\n' "⚠ Could not fetch token for existing runner. Creating new runner instead."
    EXISTING_ID=""
  fi
fi

if [[ -z "${EXISTING_ID}" || ! "${EXISTING_ID}" =~ ^[0-9]+$ ]]; then
  # Create new runner via API
  API_RESPONSE=$(curl -sf --header "PRIVATE-TOKEN: ${GITLAB_PAT}" \
    --request POST "https://${GITLAB_DOMAIN}/api/v4/user/runners" \
    --form "runner_type=instance_type" \
    --form "description=${RUNNER_NAME}" \
    --form "tag_list=${RUNNER_TAGS}" \
    --form "run_untagged=true")

  RUNNER_TOKEN=$(printf '%s' "${API_RESPONSE}" | jq -r '.token // empty')
  RUNNER_API_ID=$(printf '%s' "${API_RESPONSE}" | jq -r '.id // empty')

  if [[ -z "${RUNNER_TOKEN}" ]]; then
    printf '%s\n' "✗ Failed to create runner token. API response:"
    printf '%s\n' "${API_RESPONSE}"
    exit 1
  fi
  printf '%s\n' "✓ Runner token created (ID: ${RUNNER_API_ID})"
fi

# ─── Step 6: Register the runner ────────────────────────────────────────────
printf '%s\n' "→ Registering runner with GitLab..."
# With glrt- tokens (new creation flow), tags/description are set via the API,
# not at registration. Only url, token, and executor are allowed here.
gitlab-runner register \
  --non-interactive \
  --url "https://${GITLAB_DOMAIN}" \
  --token "${RUNNER_TOKEN}" \
  --executor shell
printf '%s\n' "✓ Runner registered"

# ─── Step 7: Start + verify ─────────────────────────────────────────────────
printf '%s\n' "→ Starting runner service..."
gitlab-runner start 2>/dev/null || true
gitlab-runner verify
printf '%s\n' "✓ Runner is alive"

printf '\n'
printf '%s\n' "→ Runner version:"
gitlab-runner --version

# ─── Step 8: Install CI tools from runner-apps.json ──────────────────────────
printf '\n'
APPS_SCRIPT=""
if [[ -f /tmp/runner-apps.sh ]]; then
  APPS_SCRIPT="/tmp/runner-apps.sh"
elif [[ -f "${SCRIPT_DIR}/runner-apps.sh" ]]; then
  APPS_SCRIPT="${SCRIPT_DIR}/runner-apps.sh"
fi

if [[ -n "${APPS_SCRIPT}" ]]; then
  printf '%s\n' "── Installing CI tools ──"
  printf '\n'
  bash "${APPS_SCRIPT}"
else
  printf '%s\n' "⚠ runner-apps.sh not found — skipping CI tools install"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
trap - ERR
printf '\n'
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  External GitLab Runner ready"
printf '%s\n' "  Name:     ${RUNNER_NAME}"
printf '%s\n' "  Executor: shell"
printf '%s\n' "  Tags:     ${RUNNER_TAGS}"
printf '%s\n' "  GitLab:   https://${GITLAB_DOMAIN}"
printf '%s\n' "  Config:   /etc/gitlab-runner/config.toml"
printf '%s\n' "  Admin:    https://${GITLAB_DOMAIN}/admin/runners"
printf '%s\n' "════════════════════════════════════════════════════"
