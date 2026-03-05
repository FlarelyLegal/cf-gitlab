[root](../README.md) / **cloudflare**

# Cloudflare Scripts

Scripts that provision Cloudflare rules and configure time sync via the Cloudflare API. All run locally and require `CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL` + `CLOUDFLARE_ACCOUNT_ID` in your shell environment (Global API key).

## Subdirectories

| Directory               | Description                                                               |
| ----------------------- | ------------------------------------------------------------------------- |
| [`waf/`](waf/README.md) | WAF custom rules, cache rules, rate limit rules (all support `--dry-run`) |
| [`zt/`](zt/README.md)   | Zero Trust config: Access apps, tunnel, service tokens (API reference)    |

## Other Scripts

| Script      | Description                                            |
| ----------- | ------------------------------------------------------ |
| `timing.sh` | Installs chrony with Cloudflare NTS as the time source |

Requires `CF_ZONE_ID` and `CDN_DOMAIN` in `.env` (at repo root).
