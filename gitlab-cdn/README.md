[← Back to root](../README.md)

# GitLab CDN Worker

Cloudflare Worker that acts as a caching CDN proxy for GitLab static objects (raw file downloads and repository archives), connected to the private GitLab instance via Workers VPC tunnel binding.

## Architecture

```text
User → Cloudflare Edge (cached) → Workers VPC Service → cloudflared tunnel → GitLab nginx → R2
```

The Worker intercepts `/raw/` and `/-/archive/` requests on `CDN_DOMAIN`, caches public responses at the edge, and adds CORS headers. It reaches the private GitLab instance through a [Workers VPC Service](https://developers.cloudflare.com/workers-vpc/), so the origin is never exposed to the public internet.

### What gets cached

| Content type                     | Cache behavior                                  | TTL                       |
| -------------------------------- | ----------------------------------------------- | ------------------------- |
| Public raw files (`/raw/`)       | Cached at edge, `X-Cache: HIT` on cache hit     | Browser: 1h, Edge: 24h    |
| Public archives (`/-/archive/`)  | Cached at edge, `X-Cache: HIT` on cache hit     | Browser: 1h, Edge: 24h    |
| Private content (`?token=` auth) | Never cached, `X-Cache: BYPASS`                 | `Cache-Control: no-store` |
| Conditional (`If-None-Match`)    | Revalidated with origin, `X-Cache: REVALIDATED` | ETag-based                |

### How it relates to R2

The CDN Worker does **not** read from R2 directly. The flow is:

1. Worker receives request on `cdn.gitlab.example.com`
2. Worker fetches from GitLab origin via VPC tunnel (HTTP to `127.0.0.1`)
3. GitLab Rails fetches the object from R2 via S3 API (`proxy_download = true`)
4. GitLab streams the response back through the tunnel to the Worker
5. Worker caches the response at Cloudflare's edge for subsequent requests

On cache hit, steps 2-4 are skipped entirely — the edge serves the cached response directly. This offloads bandwidth from both the GitLab instance and R2.

## Setup

### 1. Prerequisites

- `cloudflared` tunnel running on the GitLab LXC (see main README [Prerequisites Step 2](../README.md#2-cloudflare-tunnel))
- VPC Service ID, created via the [Workers VPC API](https://developers.cloudflare.com/workers-vpc/configuration/vpc-services/) or the [Zero Trust dashboard](https://dash.cloudflare.com/one) → Networks → Connectors → Cloudflare Tunnels → your tunnel
- `CDN_DOMAIN` DNS record (created automatically by `wrangler deploy` via `custom_domain`)

### 2. Configure

Set the following in the parent `../.env` (see `.env.example`):

```bash
CDN_DOMAIN="cdn.gitlab.example.com"
CDN_WORKER_NAME="cdn-gitlab"          # optional, defaults to cdn-gitlab
VPC_SERVICE_ID="<your-vpc-service-id>"
```

Then generate `wrangler.jsonc`:

```bash
./generate-wrangler.sh            # writes wrangler.jsonc from ../.env
./generate-wrangler.sh --dry-run  # preview without writing
```

### 3. Deploy

```bash
npm install
./generate-wrangler.sh                  # generate wrangler.jsonc
npm run deploy
npx wrangler secret put STORAGE_TOKEN   # set the shared auth token
```

### 4. Enable in GitLab

Admin → Settings → Repository → **Static Objects External Storage**:

- **URL:** `https://cdn.gitlab.example.com`
- **Token:** same value as `STORAGE_TOKEN`

This tells GitLab to rewrite raw file and archive download URLs to point at the CDN Worker instead of serving them directly.

## Secrets

| Secret          | Description                                         |
| --------------- | --------------------------------------------------- |
| `STORAGE_TOKEN` | Shared auth token between GitLab and the CDN Worker |

Set via `npx wrangler secret put STORAGE_TOKEN`. Also configured in GitLab admin (Step 4 above).

## Environment Variables

| Variable                | Description                                               |
| ----------------------- | --------------------------------------------------------- |
| `CACHE_PRIVATE_OBJECTS` | Set to `true` to cache private repo objects (default: no) |

Set in `.dev.vars` for local development or via the Cloudflare dashboard for production.

## Features

- **Workers VPC** — reaches the private GitLab origin through a [VPC Service](https://developers.cloudflare.com/workers-vpc/) (no public exposure)
- **Smart Placement** — Worker runs at the edge closest to the origin for optimal latency
- **Edge caching** — public content cached at Cloudflare's edge (24h edge TTL, 1h browser TTL)
- **ETag revalidation** — conditional requests (`If-None-Match`) revalidate with origin, returning 304 when content hasn't changed
- **Query normalization** — strips irrelevant query parameters to maximize cache hit ratio (only `inline`, `append_sha`, `path` are kept)
- **CORS headers** — enables cross-origin embedding of raw files
- **Analytics Engine** — tracks cache status, latency, content size, and path type per request
- **Auth passthrough** — private content (`?token=` requests) is proxied without caching

## Development

```bash
npm run dev --remote   # wrangler dev (requires --remote for VPC bindings)
npm run deploy         # wrangler deploy (production)
npm run typecheck      # tsc --noEmit
npm run lint           # eslint
npm run format         # prettier
```

> `--remote` is required for local development because Workers VPC bindings don't work in local mode.

## Files

| File                   | Description                                                |
| ---------------------- | ---------------------------------------------------------- |
| `src/index.ts`         | Worker source — proxy, caching, analytics                  |
| `generate-wrangler.sh` | Generates `wrangler.jsonc` from `../.env` values           |
| `wrangler.jsonc`       | **Generated** — do not edit directly (gitignored)          |
| `package.json`         | Dependencies (wrangler, workers-types, typescript)         |
| `tsconfig.json`        | TypeScript config                                          |
| `.dev.vars.example`    | Template for local development secrets                     |
| `.gitignore`           | Ignores node_modules, .wrangler, .dev.vars, wrangler.jsonc |
