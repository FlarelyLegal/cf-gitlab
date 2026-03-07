[root](../../README.md) / [optional](../README.md) / **glitchtip**

# GlitchTip + Caddy

Sentry-compatible error tracking via [GlitchTip](https://glitchtip.com), fronted by Caddy with Docker label auto-discovery and Certbot DNS-01 certs via Cloudflare. Certificates auto-renew twice daily inside the Caddy container.

> **Note:** The Caddy stack is a general-purpose reverse proxy. It is not specific to GlitchTip. Any container on the `caddy` network with the right labels gets proxied automatically.

> The Caddy image is a custom build (`xcaddy`) with the [Cloudflare DNS](https://github.com/caddy-dns/cloudflare) and [Docker Proxy](https://github.com/lucaslorentz/caddy-docker-proxy) plugins. TLS is handled by Certbot rather than Caddy's native ACME issuer to stay consistent with the rest of the infrastructure. Pre-built images are available at [`registry.gitlab.com/taslabs-net/gitlab-self-hosted/caddy`](https://gitlab.com/taslabs-net/gitlab-self-hosted/container_registry).

## Caddy Auto-Proxy

```yaml
labels:
  caddy: app.example.com
  caddy.tls: /etc/letsencrypt/live/app.example.com/fullchain.pem /etc/letsencrypt/live/app.example.com/privkey.pem
  caddy.reverse_proxy: "{{upstreams 8080}}"
```

## GitLab Integration

**Instance-wide** -- in `/etc/gitlab/gitlab.rb`:

```ruby
gitlab_rails['sentry_enabled'] = true
gitlab_rails['sentry_dsn'] = 'https://<key>@glitchtip.example.com/<project_id>'
gitlab_rails['sentry_environment'] = 'production'
```

**Per-project** -- **Settings > Monitor > Error Tracking** with the GlitchTip API URL and an auth token from **GlitchTip > Profile > Auth Tokens**.

> Instance-wide tracks errors from the GitLab application itself. Per-project tracks errors from your own applications via Sentry SDKs. Both can be used at the same time.

## OIDC

Set `OIDC_ENABLED=true` in `glitchtip/.env`, fill in the OIDC variables, then run `setup-oidc.sh`. Register the callback URL in your identity provider:

```text
{GLITCHTIP_DOMAIN}/accounts/oidc/{OIDC_PROVIDER_ID}/login/callback/
```

## Ports

| Port | Service | Notes                                |
| ---- | ------- | ------------------------------------ |
| 80   | Caddy   | HTTP -> HTTPS redirect               |
| 443  | Caddy   | HTTPS + HTTP/3                       |
| 5003 | Caddy   | Admin API (`CADDY_API_ENABLED=true`) |
