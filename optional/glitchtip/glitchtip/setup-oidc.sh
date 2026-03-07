#!/bin/sh
set -eu

ENV_FILE="/opt/stacks/glitchtip/.env"
COMPOSE="/opt/stacks/glitchtip/compose.yaml"

# Source env vars (skip comments and empty lines)
# shellcheck disable=SC2046
export $(grep -v '^\s*#' "$ENV_FILE" | grep -v '^\s*$' | xargs)

if [ "$OIDC_ENABLED" != "true" ]; then
  printf 'OIDC_ENABLED is not true in %s — nothing to do.\n' "$ENV_FILE"
  exit 0
fi

for var in OIDC_PROVIDER_NAME OIDC_PROVIDER_ID OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_SERVER_URL; do
  eval val=\$$var
  if [ -z "$val" ]; then
    printf 'Error: %s is not set in %s\n' "$var" "$ENV_FILE"
    exit 1
  fi
done

# Convert shell true/false to Python True/False
PKCE_PYTHON="False"
if [ "${OIDC_PKCE:-false}" = "true" ]; then
  PKCE_PYTHON="True"
fi

printf 'Configuring OIDC provider: %s (%s)\n' "$OIDC_PROVIDER_NAME" "$OIDC_PROVIDER_ID"
printf '  PKCE: %s\n' "${OIDC_PKCE:-false}"

docker compose -f "$COMPOSE" exec -T web python manage.py shell -c "
from allauth.socialaccount.models import SocialApp

app, created = SocialApp.objects.update_or_create(
    provider='openid_connect',
    provider_id='${OIDC_PROVIDER_ID}',
    defaults={
        'name': '${OIDC_PROVIDER_NAME}',
        'client_id': '${OIDC_CLIENT_ID}',
        'secret': '${OIDC_CLIENT_SECRET}',
        'settings': {
            'server_url': '${OIDC_SERVER_URL}',
            'oauth_pkce_enabled': ${PKCE_PYTHON},
        },
    }
)
print(f'SocialApp {\"created\" if created else \"updated\"}: {app.name}')
"

printf 'Done. Callback URL: %s/accounts/oidc/%s/login/callback/\n' "${GLITCHTIP_DOMAIN}" "${OIDC_PROVIDER_ID}"
