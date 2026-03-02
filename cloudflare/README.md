[root](../README.md) / **cloudflare**

# Cloudflare Scripts

Scripts that provision Cloudflare rules and configure time sync via the Cloudflare API. All run locally and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` + `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key).

## Directory Structure

```text
cloudflare/
├── waf/
│   ├── waf-rules.sh         # WAF custom rules (skip CDN Worker traffic, block other CDN access)
│   ├── cache-rules.sh       # Cache rules (edge + browser TTLs for public objects, token bypass)
│   └── ratelimit-rules.sh   # Rate limit rule for health endpoints (20 req/60s per IP)
├── zt/
│   └── README.md            # Zero Trust config: Access apps, tunnel, service tokens (API reference)
├── timing.sh                # Installs chrony with Cloudflare NTS as the time source
└── README.md
```

## WAF Scripts (`waf/`)

| Script               | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `waf-rules.sh`       | WAF custom rules (skip CDN Worker traffic, block other CDN access) |
| `cache-rules.sh`     | Cache rules (edge + browser TTLs for public objects, token bypass) |
| `ratelimit-rules.sh` | Rate limit rule for health endpoints (20 req/60s per IP)           |

All WAF scripts support `--dry-run` and use read-merge-write to preserve existing non-CDN rules in the same phase.

## Zero Trust (`zt/`)

API reference for the Cloudflare Access applications, tunnel configuration, and service tokens that protect the GitLab instance. See [`zt/README.md`](zt/README.md).

## Other Scripts

| Script      | Description                                            |
| ----------- | ------------------------------------------------------ |
| `timing.sh` | Installs chrony with Cloudflare NTS as the time source |

Requires `CF_ZONE_ID` and `CDN_DOMAIN` in `.env` (at repo root).
