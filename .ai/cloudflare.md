# Cloudflare Integration

## Architecture

GitLab is never exposed directly to the internet. The full traffic flow:

```text
User → Cloudflare Access (OIDC) → Cloudflare Tunnel → GitLab LXC
```

## Components

### Cloudflare Tunnel

All HTTP/SSH access to GitLab, the container registry, and GitLab Pages
flows through a Cloudflare Tunnel. No ports are open on the LXC firewall
except for the local network (UFW rules in `setup.sh`).

### Zero Trust / Access

Cloudflare Access provides OIDC-based SSO. The `sso-only.sh` script locks
down GitLab to SSO-only login, disabling password authentication.

Configuration reference lives in `cloudflare/zt/`.

### R2 Object Storage

Ten dedicated R2 buckets handle all GitLab object storage, keeping the LXC
disk small (~50 GB for Git repos, PostgreSQL, and binaries only). Buckets
are configured in `gitlab.rb` via S3-compatible endpoints.

### CDN Worker

The `gitlab-cdn/` directory contains a Cloudflare Worker (TypeScript) that
acts as a caching proxy for GitLab assets. It connects to the GitLab origin
via a Workers VPC tunnel binding (not public internet).

- Source: `gitlab-cdn/src/index.ts`
- Tests: `gitlab-cdn/src/__tests__/`
- Config: `gitlab-cdn/wrangler.jsonc` (generated from `.env` by
  `generate-wrangler.sh`)
- Deploy guide: `gitlab-cdn/deploy.md`

### WAF / Cache / Rate Limiting

Cloudflare WAF, cache, and rate limiting rules are provisioned via API
scripts in `cloudflare/waf/`.

### TLS

Let's Encrypt certificates via Certbot with Cloudflare DNS-01 challenges.
Three domains plus wildcard are covered. The Cloudflare API token used by
Certbot is scoped narrowly and pushed to the LXC by `deploy.sh`.

### NTS Time Sync

Chrony is configured to use Cloudflare's NTS (Network Time Security)
endpoint. Config lives in `config/chrony.conf`, installed by
`cloudflare/timing.sh`.

## Secrets Separation

- The Cloudflare Global API Key stays in the local shell environment and is
  never committed or pushed to the LXC.
- Only a scoped Certbot API token reaches the LXC.
- R2 credentials are configured as GitLab CI/CD variables or in `gitlab.rb`
  on the LXC.
