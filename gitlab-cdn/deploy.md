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

## 3. Provision WAF + Cache Rules

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
