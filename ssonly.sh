#!/usr/bin/env bash
set -euo pipefail

# ─── SSO-Only Lockdown ───────────────────────────────────────────────────────
# Disables manual signup and password-based login on GitLab, enables auto
# sign-in via OIDC, forcing all authentication through Cloudflare Access.
#
# Changes two things:
#   1. Application settings (DB): disable signup + password login
#   2. gitlab.rb config: enable auto_sign_in_with_provider (skips login page)
#
# Run this AFTER verifying SSO works (Step 6 in the README).
#
# Usage:
#   bash ssonly.sh              # apply changes
#   bash ssonly.sh --dry-run    # show current state without changes
#   bash ssonly.sh --revert     # re-enable signup + password login + remove auto sign-in
#
# Must be run on the GitLab LXC (requires gitlab-rails + gitlab-ctl).
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=false
REVERT=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
elif [[ "${1:-}" == "--revert" ]]; then
  REVERT=true
fi

# ─── Error handling ───────────────────────────────────────────────────────────
trap 'printf "\n"; printf "%s\n" "✗ SSO lockdown failed at line ${LINENO}."' ERR

# ─── Verify we're on the GitLab host ─────────────────────────────────────────
if ! command -v gitlab-rails >/dev/null 2>&1; then
  printf '%s\n' "✗ gitlab-rails not found. This script must run on the GitLab LXC."
  exit 1
fi

# ─── Read current state ──────────────────────────────────────────────────────
printf '%s\n' "→ Reading current application settings (this takes ~45s to load Rails)..."
CURRENT=$(gitlab-rails runner "
s = Gitlab::CurrentSettings.current_application_settings
puts \"signup_enabled=#{s.signup_enabled}\"
puts \"password_authentication_enabled_for_web=#{s.password_authentication_enabled_for_web}\"
" 2>/dev/null)

SIGNUP=$(printf '%s\n' "${CURRENT}" | grep '^signup_enabled=' | cut -d= -f2)
PASSWORD=$(printf '%s\n' "${CURRENT}" | grep '^password_authentication_enabled_for_web=' | cut -d= -f2)

# Check gitlab.rb for auto_sign_in
AUTO_SIGNIN="not set"
if grep -q "omniauth_auto_sign_in_with_provider" /etc/gitlab/gitlab.rb 2>/dev/null; then
  AUTO_SIGNIN=$(grep "omniauth_auto_sign_in_with_provider" /etc/gitlab/gitlab.rb | grep -o "'[^']*'" | tail -1 | tr -d "'")
fi

printf '\n'
printf '%s\n' "  Current state:"
printf '%s\n' "    signup_enabled:                          ${SIGNUP}"
printf '%s\n' "    password_authentication_enabled_for_web:  ${PASSWORD}"
printf '%s\n' "    auto_sign_in_with_provider:               ${AUTO_SIGNIN}"
printf '\n'

# ─── Dry run ──────────────────────────────────────────────────────────────────
if ${DRY_RUN}; then
  NEEDS_CHANGE=false
  if [[ "${SIGNUP}" != "false" || "${PASSWORD}" != "false" || "${AUTO_SIGNIN}" != "openid_connect" ]]; then
    NEEDS_CHANGE=true
    printf '%s\n' "  Would change:"
    [[ "${SIGNUP}" != "false" ]] && printf '%s\n' "    signup_enabled:                          → false"
    [[ "${PASSWORD}" != "false" ]] && printf '%s\n' "    password_authentication_enabled_for_web:  → false"
    [[ "${AUTO_SIGNIN}" != "openid_connect" ]] && printf '%s\n' "    auto_sign_in_with_provider:               → openid_connect"
  fi

  if ${NEEDS_CHANGE}; then
    [[ "${AUTO_SIGNIN}" != "openid_connect" ]] && printf '%s\n' "" && printf '%s\n' "  gitlab-ctl reconfigure will be required (auto_sign_in is a gitlab.rb setting)."
    printf '\n'
    printf '%s\n' "✓ Dry run complete. Run without --dry-run to apply."
  else
    printf '%s\n' "✓ Already locked down to SSO-only. No changes needed."
  fi
  exit 0
fi

# ─── Revert ───────────────────────────────────────────────────────────────────
if ${REVERT}; then
  printf '%s\n' "→ Re-enabling signup and password login..."
  gitlab-rails runner "
    s = Gitlab::CurrentSettings.current_application_settings
    s.update!(signup_enabled: true, password_authentication_enabled_for_web: true)
    puts 'signup_enabled: ' + s.signup_enabled.to_s
    puts 'password_authentication_enabled_for_web: ' + s.password_authentication_enabled_for_web.to_s
  " 2>/dev/null

  printf '%s\n' "→ Removing auto_sign_in_with_provider from gitlab.rb..."
  sed -i "/omniauth_auto_sign_in_with_provider/d" /etc/gitlab/gitlab.rb

  printf '%s\n' "→ Reconfiguring GitLab..."
  gitlab-ctl reconfigure >/tmp/gitlab-reconfigure.log 2>&1 || {
    printf '%s\n' "✗ Reconfigure failed. See /tmp/gitlab-reconfigure.log"
    exit 1
  }

  trap - ERR
  printf '\n'
  printf '%s\n' "✓ Reverted — signup, password login, and manual sign-in page restored."
  exit 0
fi

# ─── Apply SSO-only lockdown ─────────────────────────────────────────────────
# 1. Application settings (DB)
if [[ "${SIGNUP}" != "false" || "${PASSWORD}" != "false" ]]; then
  printf '%s\n' "→ Disabling signup and password login..."
  gitlab-rails runner "
    s = Gitlab::CurrentSettings.current_application_settings
    s.update!(signup_enabled: false, password_authentication_enabled_for_web: false)
    puts 'signup_enabled: ' + s.signup_enabled.to_s
    puts 'password_authentication_enabled_for_web: ' + s.password_authentication_enabled_for_web.to_s
  " 2>/dev/null
else
  printf '%s\n' "✓ Signup and password login already disabled"
fi

# 2. Auto sign-in (gitlab.rb)
if [[ "${AUTO_SIGNIN}" != "openid_connect" ]]; then
  printf '%s\n' "→ Enabling auto sign-in via OIDC..."
  # Remove any existing auto_sign_in line, then add after auto_link_user
  sed -i "/omniauth_auto_sign_in_with_provider/d" /etc/gitlab/gitlab.rb
  sed -i "/omniauth_auto_link_user/a\\
gitlab_rails['omniauth_auto_sign_in_with_provider'] = 'openid_connect'" /etc/gitlab/gitlab.rb

  printf '%s\n' "→ Reconfiguring GitLab (this may take a moment)..."
  gitlab-ctl reconfigure >/tmp/gitlab-reconfigure.log 2>&1 || {
    printf '%s\n' "✗ Reconfigure failed. See /tmp/gitlab-reconfigure.log"
    exit 1
  }
else
  printf '%s\n' "✓ Auto sign-in already enabled"
fi

trap - ERR
printf '\n'
printf '%s\n' "════════════════════════════════════════════════════"
printf '%s\n' "  SSO-only lockdown applied"
printf '%s\n' "  Signup:       disabled"
printf '%s\n' "  Password:     disabled"
printf '%s\n' "  Auto sign-in: openid_connect (skips login page)"
printf '%s\n' "  Login via:    Cloudflare Access (OIDC) + GitHub"
printf '\n'
printf '%s\n' "  Bypass auto sign-in (manual login page):"
printf '%s\n' "    https://<GITLAB_DOMAIN>/users/sign_in?auto_sign_in=false"
printf '\n'
printf '%s\n' "  Emergency root access:"
printf '%s\n' "    gitlab-rails runner \"Gitlab::CurrentSettings.current_application_settings.update!(password_authentication_enabled_for_web: true)\""
printf '%s\n' "════════════════════════════════════════════════════"
