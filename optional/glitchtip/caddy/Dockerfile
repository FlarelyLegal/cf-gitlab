ARG CADDY_VERSION=2
FROM caddy:${CADDY_VERSION}-builder AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare \
    --with github.com/lucaslorentz/caddy-docker-proxy/v2

FROM caddy:${CADDY_VERSION}-alpine

RUN apk add --no-cache certbot certbot-dns-cloudflare

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["caddy", "docker-proxy"]
