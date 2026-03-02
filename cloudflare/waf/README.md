[root](../../README.md) / [cloudflare](../README.md) / **waf**

# WAF, Cache, and Rate Limit Rules

Scripts that provision Cloudflare zone rulesets via the API. All run locally and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` + `CLOUDFLARE_ACCOUNT_ID` in your shell environment.

| Script               | Phase                          | Description                                          |
| -------------------- | ------------------------------ | ---------------------------------------------------- |
| `waf-rules.sh`       | `http_request_firewall_custom` | Skip CDN Worker traffic, block other CDN access      |
| `cache-rules.sh`     | `http_request_cache_settings`  | Edge + browser TTLs for public objects, token bypass |
| `ratelimit-rules.sh` | `http_ratelimit`               | Rate limit health endpoints (20 req/60s per IP)      |

All scripts support `--dry-run` and use **read-merge-write** to preserve existing non-CDN rules in the same phase.

Requires `CF_ZONE_ID` and `CDN_DOMAIN` in `.env` (at repo root).
