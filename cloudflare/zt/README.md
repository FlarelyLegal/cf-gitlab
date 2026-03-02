[root](../../README.md) / [cloudflare](../README.md) / **zt**

# Zero Trust Configuration

Cloudflare Access applications and tunnel configuration for the GitLab instance. These are managed via the Cloudflare API (or dashboard) and are documented here for reproducibility.

All API commands use the Global API key (`CLOUDFLARE_API_KEY` + `CLOUDFLARE_EMAIL`) and target the account ID in `CLOUDFLARE_ACCOUNT_ID`.

## Tunnel

A single Cloudflare Tunnel (`gitlab`) connects the LXC to Cloudflare with two ingress rules:

| Hostname                 | Service              | Notes                               |
| ------------------------ | -------------------- | ----------------------------------- |
| `gitlab.example.com`     | `https://127.0.0.1`  | noTLSVerify, disableChunkedEncoding |
| `ssh.gitlab.example.com` | `ssh://127.0.0.1:22` | disableChunkedEncoding              |
| (catch-all)              | `http_status:404`    |                                     |

```bash
# List tunnels
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel?is_deleted=false" \
  | jq '.result[] | {id, name, status}'

# Get tunnel config
TUNNEL_ID="<tunnel-id>"
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  | jq '.result.config'
```

## Access Applications

Four Access applications protect the GitLab domain. The main app requires authentication via Google Workspace. Two path-scoped bypass apps allow external services (Linear, Mailgun) to reach GitLab without Access authentication.

| App Name              | Type        | Domain / Path                           | Policy                   |
| --------------------- | ----------- | --------------------------------------- | ------------------------ |
| GitLab                | self_hosted | `gitlab.example.com`                    | Allow (Google Workspace) |
| Gitlab (OIDC)         | saas        | OIDC endpoint for OmniAuth              | Allow (Google Workspace) |
| GitLab API Bypass     | self_hosted | `gitlab.example.com/api/v4`             | Bypass (everyone)        |
| GitLab Webhook Bypass | self_hosted | `gitlab.example.com/-/mailgun/webhooks` | Bypass (everyone)        |

### List all Access apps

```bash
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps" \
  | jq '.result[] | {id, name, type, domain}'
```

### Get policies for an app

```bash
APP_ID="<app-id>"
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  | jq '.result[] | {id, name, decision, include}'
```

### Create a path-scoped bypass app

Use this pattern when an external service needs to reach a GitLab endpoint without going through Access (e.g., webhooks, API integrations):

```bash
# 1. Create the app
curl -s -X POST -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps" \
  --data '{
    "name": "GitLab <Service> Bypass",
    "domain": "gitlab.example.com/<path>",
    "type": "self_hosted",
    "session_duration": "24h"
  }' | jq '{id: .result.id, name: .result.name}'

# 2. Add a bypass policy
APP_ID="<app-id-from-step-1>"
curl -s -X POST -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/apps/$APP_ID/policies" \
  --data '{
    "name": "Bypass - Everyone",
    "decision": "bypass",
    "include": [{"everyone": {}}],
    "precedence": 1
  }' | jq '{id: .result.id, name: .result.name, decision: .result.decision}'
```

The path-scoped app takes priority over the wildcard domain app because Access evaluates the most specific path match first.

### List identity providers

```bash
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/identity_providers" \
  | jq '.result[] | {id, name, type}'
```

## Service Tokens

Service tokens can be used for machine-to-machine authentication with Access. A token was created for Linear webhooks but is **unused** because Cloudflare Snippets run after Access in the request pipeline, making header injection non-viable.

```bash
# List service tokens
curl -s -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/service_tokens" \
  | jq '.result[] | {id, name, client_id}'

# Delete a service token
TOKEN_ID="<token-id>"
curl -s -X DELETE -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
  -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
  "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID/access/service_tokens/$TOKEN_ID"
```
