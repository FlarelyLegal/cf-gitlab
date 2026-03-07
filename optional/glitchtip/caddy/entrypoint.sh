#!/bin/sh
set -eu

if [ "${CADDY_API_ENABLED:-false}" = "true" ]; then
  export CADDY_ADMIN="0.0.0.0:2019"
else
  export CADDY_ADMIN="localhost:2019"
fi

# Auto-renew certificates twice daily (certbot skips if not due)
printf '12 3,15 * * * certbot renew --quiet --deploy-hook "caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true"\n' \
  | crontab -
crond

exec "$@"
