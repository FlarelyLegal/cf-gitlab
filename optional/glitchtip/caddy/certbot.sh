#!/bin/sh
set -eu

COMPOSE="/opt/stacks/caddy/compose.yaml"
ENV_FILE="/opt/stacks/caddy/.env"

# shellcheck source=/dev/null
. "$ENV_FILE"

case "${1:-}" in
  issue)
    domain="${2:-$ROOT_DOMAIN}"
    docker compose -f "$COMPOSE" exec caddy certbot certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials /etc/certbot/cloudflare.ini \
      --dns-cloudflare-propagation-seconds 30 \
      -d "$domain" \
      --agree-tos \
      --email "$ACME_EMAIL" \
      --non-interactive \
      --keep-until-expiring
    docker compose -f "$COMPOSE" exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
    ;;
  renew)
    docker compose -f "$COMPOSE" exec caddy certbot renew --quiet
    docker compose -f "$COMPOSE" exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
    ;;
  *)
    printf 'Usage: %s {issue [domain]|renew}\n' "$0"
    printf '  issue          - Issue cert for ROOT_DOMAIN (%s)\n' "$ROOT_DOMAIN"
    printf '  issue <domain> - Issue cert for a specific domain\n'
    printf '  renew          - Renew all certs\n'
    exit 1
    ;;
esac
