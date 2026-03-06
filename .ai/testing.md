# Testing Conventions

## CDN Worker (TypeScript)

The `gitlab-cdn/` Cloudflare Worker has unit tests using Vitest.

### Running Tests

- **Local**: `npm test` (in `gitlab-cdn/`)
- **CI**: `npm run test:ci` (produces JUnit XML at `junit-cdn.xml`)

### Test Structure

Tests live in `gitlab-cdn/src/__tests__/` alongside the source code.

### CI Integration

The `cdn:test` job in `.gitlab-ci.yml` runs on changes to `gitlab-cdn/**`
and uploads JUnit results to the MR widget.

## Shell Scripts

Shell scripts are validated by CI linters (shellcheck, shfmt, printf-check,
executable-check) rather than unit tests. The `--dry-run` flag on deployment
scripts serves as the primary manual verification method.

## Validation Script

`scripts/validate.sh` is a read-only health check that verifies the GitLab
instance is correctly configured. It checks services, certificates, storage,
and connectivity without making changes.
