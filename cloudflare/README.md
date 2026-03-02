[← Back to root](../README.md)

# Cloudflare Scripts

Scripts that provision Cloudflare rules and configure time sync via the Cloudflare API. All run locally and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` + `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key).

| Script                 | Description                                                        |
| ---------------------- | ------------------------------------------------------------------ |
| `waf-rules.sh`         | WAF custom rules (skip CDN Worker traffic, block other CDN access) |
| `cache-rules.sh`       | Cache rules (edge + browser TTLs for public objects, token bypass) |
| `ratelimit-rules.sh`   | Rate limit rule for health endpoints (20 req/60s per IP)           |
| `cloudflare-timing.sh` | Installs chrony with Cloudflare NTS as the time source             |

All scripts support `--dry-run` and use read-merge-write to preserve existing non-CDN rules in the same phase.

Requires `CF_ZONE_ID` and `CDN_DOMAIN` in `.env` (at repo root).
