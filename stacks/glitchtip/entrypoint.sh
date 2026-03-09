#!/bin/sh

OIDC_PROVIDER_ID="${OIDC_PROVIDER_ID:-cloudflare-access}"

printf '\n'
printf '  OIDC Callback: %s/accounts/oidc/%s/login/callback/\n' "${GLITCHTIP_DOMAIN:-}" "${OIDC_PROVIDER_ID}"
printf '\n'

cd /code || exit 1
exec ./bin/start.sh
