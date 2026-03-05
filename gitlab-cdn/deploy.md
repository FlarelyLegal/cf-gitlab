[root](../README.md) / [gitlab-cdn](README.md) / **deploy**

# CDN Worker Deployment

The CDN Worker caches public raw file and archive downloads at Cloudflare's edge, offloading
bandwidth from the GitLab instance. It connects to the private origin via a
[Workers VPC Service](https://developers.cloudflare.com/workers-vpc/)
through the `cloudflared` tunnel, so the origin is never exposed publicly.

## 1. Deploy the CDN Worker

Ensure `CDN_DOMAIN`, `VPC_SERVICE_ID`, and optionally `CDN_WORKER_NAME` are set in `.env`.

First, generate a random shared auth token. The CDN Worker sends this token to GitLab when
fetching content through the tunnel, and GitLab verifies it before serving the response. Both
sides must use the same value.

```bash
# Generate a random token
openssl rand -base64 32
```

Save the output. You will need it twice: once for the Worker secret and once for GitLab admin.

```bash
cd gitlab-cdn/
npm install
./generate-wrangler.sh                   # generates wrangler.jsonc from ../.env
npm run deploy
npx wrangler secret put STORAGE_TOKEN    # paste the token you generated above
```

## 2. Enable in GitLab

Admin -> Settings -> Repository -> **Static Objects External Storage**:

- **URL:** `https://cdn.gitlab.example.com`
- **Token:** paste the same token from step 1

## 3. Set up GitLab Webhook Notifications (optional)

The CDN Worker can optionally receive GitLab webhook events and send email notifications via
[Email Routing](https://developers.cloudflare.com/email-routing/email-workers/send-email-workers/).
This feature is **opt-in** — it is completely inactive unless you enable it.

### Enable the feature

Set `ENABLE_WEBHOOK_EMAIL=true` in `.env`, then regenerate and redeploy:

```bash
./generate-wrangler.sh
npm run deploy
```

This adds the `send_email` binding to the Worker. Without it, the `/webhook/gitlab`
endpoint returns 404.

### Prerequisites

- Email Routing enabled on the zone
- At least one verified destination address in Email Routing
- If sending from a subdomain, the subdomain must have email routing configured
  with **email sending enabled** in the dashboard

### Set the Worker secrets

All email configuration is stored as Worker secrets — no addresses are hardcoded.

```bash
# Webhook authentication (shared with GitLab)
openssl rand -base64 32
npx wrangler secret put WEBHOOK_SECRET        # paste the token you generated

# Email recipient(s) — comma-separated verified destination addresses
npx wrangler secret put WEBHOOK_RECIPIENT     # e.g. "admin@example.com,team@example.com"

# Sender address — must be on a domain with Email Routing active
npx wrangler secret put WEBHOOK_FROM          # e.g. "noreply@gitlab.example.com"
npx wrangler secret put WEBHOOK_FROM_NAME     # e.g. "GitLab CDN"
```

### Configure the webhook in GitLab

Admin -> Settings -> System Hooks (or per-project at Settings -> Webhooks):

- **URL:** `https://<CDN_DOMAIN>/webhook/gitlab`
- **Secret token:** paste the same `WEBHOOK_SECRET` from above
- **Trigger:** select the events you want notifications for (push, merge request,
  pipeline, tag push, issues, comments, deployments, releases, etc.)
- **SSL verification:** enabled

### Rotating the webhook secret

To rotate, generate a new token and update both sides:

```bash
openssl rand -base64 32
npx wrangler secret put WEBHOOK_SECRET   # paste the new token
```

Then update the **Secret token** field in GitLab's webhook settings to match.
The worker picks up the new secret immediately — no redeploy needed.

## 4. Provision WAF + Cache Rules

Requires `CF_ZONE_ID`, `CDN_DOMAIN`, and `VPC_SERVICE_ID` in `.env`.

```bash
# Preview first
./cloudflare/waf/waf-rules.sh --dry-run
./cloudflare/waf/cache-rules.sh --dry-run

# Then provision
./cloudflare/waf/waf-rules.sh
./cloudflare/waf/cache-rules.sh
```

> See [`README.md`](README.md) for full CDN Worker architecture, features, and development instructions.
