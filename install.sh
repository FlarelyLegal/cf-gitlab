#!/usr/bin/env bash
# Self-Hosted GitLab with Cloudflare - quick installer
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/FlarelyLegal/cf-gitlab/main/install.sh)"
set -euo pipefail

REPO="FlarelyLegal/cf-gitlab"
DIR="cf-gitlab"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=true
      ;;
  esac
done

# --- dependency checks --------------------------------------------------------

for cmd in git curl; do
  if ! command -v "$cmd" &>/dev/null; then
    printf "Error: %s is required but not installed.\n" "$cmd" >&2
    printf "Install it with your package manager (e.g. apt install %s).\n" "$cmd" >&2
    exit 1
  fi
done

# --- existing directory check -------------------------------------------------

if [ -d "$DIR" ]; then
  printf "Error: ./%s already exists. Remove or rename it first.\n" "$DIR" >&2
  exit 1
fi

# --- fetch latest release tag -------------------------------------------------

printf "Fetching latest release...\n"
TAG=$(
  curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep '"tag_name"' \
    | sed 's/.*: *"//;s/".*//'
)

if [ -z "$TAG" ]; then
  printf "Error: could not determine latest release.\n" >&2
  exit 1
fi

# --- clone --------------------------------------------------------------------

if "$DRY_RUN"; then
  printf "[dry-run] Would clone %s %s into ./%s\n" "$REPO" "$TAG" "$DIR"
  printf "[dry-run] Would copy .env.example to .env\n"
else
  printf "Cloning %s %s into ./%s...\n" "$DIR" "$TAG" "$DIR"
  git clone --depth 1 --branch "$TAG" "https://github.com/${REPO}.git" "$DIR" --quiet
  cp "${DIR}/.env.example" "${DIR}/.env"
  printf "Created .env from .env.example\n"
fi

# --- next steps ---------------------------------------------------------------

printf "\n"
printf -- "── Next Steps ──\n"
printf "\n"
printf "1. Edit your configuration:\n"
printf "     cd %s\n" "$DIR"
# shellcheck disable=SC2016
printf '     $EDITOR .env\n'
printf "\n"
printf "2. Set up Cloudflare API credentials in your shell:\n"
printf '     export CLOUDFLARE_API_KEY="your-global-api-key"\n'
printf '     export CLOUDFLARE_EMAIL="you@example.com"\n'
printf '     export CLOUDFLARE_ACCOUNT_ID="your-account-id"\n'
if [ "$(uname -s)" = "Darwin" ]; then
  printf "\n"
  printf "   Tip: on macOS you can store these in Keychain and load them\n"
  printf "   automatically. See the README for details.\n"
fi
printf "\n"
printf "3. Validate your setup:\n"
printf "     scripts/validate.sh --dry-run\n"
printf "\n"
printf "4. Preview the deployment:\n"
printf "     scripts/deploy.sh --dry-run\n"
printf "\n"
printf "5. Deploy:\n"
printf "     scripts/deploy.sh\n"
printf "\n"
printf "Full documentation: https://github.com/%s#readme\n" "$REPO"
