[root](../../README.md) / [stacks](../README.md) / **caddy**

# Caddy Reverse Proxy

General-purpose reverse proxy with Docker label auto-discovery and Certbot DNS-01 certs via Cloudflare. Certificates auto-renew twice daily inside the container. Any container on the `caddy` network with the right labels gets proxied automatically.

The image is a custom build (`xcaddy`) with the [Cloudflare DNS](https://github.com/caddy-dns/cloudflare) and [Docker Proxy](https://github.com/lucaslorentz/caddy-docker-proxy) plugins. TLS is handled by Certbot rather than Caddy's native ACME issuer to stay consistent with the rest of the infrastructure. Pre-built images are available at [`registry.gitlab.com/taslabs-net/gitlab-self-hosted/caddy`](https://gitlab.com/taslabs-net/gitlab-self-hosted/container_registry).

## Auto-Proxy Labels

```yaml
labels:
  caddy: app.example.com
  caddy.tls: /etc/letsencrypt/live/app.example.com/fullchain.pem /etc/letsencrypt/live/app.example.com/privkey.pem
  caddy.reverse_proxy: "{{upstreams 8080}}"
```

## Ports

| Port | Service | Notes                                |
| ---- | ------- | ------------------------------------ |
| 80   | Caddy   | HTTP -> HTTPS redirect               |
| 443  | Caddy   | HTTPS + HTTP/3                       |
| 5003 | Caddy   | Admin API (`CADDY_API_ENABLED=true`) |
