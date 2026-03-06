# Agent Guidelines

## Principles

### Zero Entropy

Every change must leave the repository more organized than before. No dead code,
no stale comments, no orphaned files, no "temporary" workarounds that persist.
If something is no longer needed, remove it in the same commit.

### Code Quality

Read @.ai/code-quality.md

### Idempotent Scripts

Every shell script must be safe to re-run. Guard destructive operations with
existence checks, use `--dry-run` flags where applicable, and never assume the
target system is in a clean state.

### Cloudflare-First Architecture

GitLab is never exposed directly to the internet. All access flows through
Cloudflare Tunnel with Zero Trust policies. R2 handles object storage. A
Workers CDN proxy caches assets. Design decisions must preserve this model.

Read @.ai/cloudflare.md

## Conventions

### Version Control

When working with git, commits, or branches: Read @.ai/git.md

### CI/CD

Read @.ai/ci.md

### Shell Scripting

Read @.ai/shell.md

### Deployment Scripts

Read @.ai/scripts.md

### CDN Worker (TypeScript)

Read @.ai/testing.md

### Code Quality

Read @.ai/code-quality.md

### Cloudflare Integration

Read @.ai/cloudflare.md
