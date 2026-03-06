# Version Control

This repo uses **jj** (Jujutsu), not raw git. Use `jj` commands for commits,
bookmarks, and pushes.

## Common Commands

```shell
jj new main                 # Start a new change from main
jj describe -m "..."        # Set commit message
jj bookmark create <name>   # Create a branch bookmark
jj push                     # Push (runs lefthook + git-cliff)
jj git fetch && jj new main # Sync with remote after merge
jj rebase -d main           # Rebase current change onto main
```

## Pushing

Always push with `jj push` (a custom alias that runs lefthook pre-push hooks
and regenerates `CHANGELOG.md` via git-cliff). Never use `jj git push`
directly — it bypasses hooks.

New bookmarks are allowed by global jj config, so no special flags are
needed for the first push.

## Branch Names

`feature/`, `fix/`, `hotfix/`, `release/`, `chore/`, `docs/`.

## Commit Messages

[Conventional Commits](https://www.conventionalcommits.org/) format.
Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`.

Note: branch prefix is `feature/` but commit type is `feat`.

## Rules

- Do not push without running linters locally first.
- Do not force-push to `main`.
- After a MR is merged, fetch and start a new change from main before the next
  piece of work: `jj git fetch && jj new main`.

## Server-Enforced Rules

The GitLab instance runs pre-receive server hooks (in `optional/`) that
**reject pushes at the server level** if they violate any of the following.
These are not advisory — the push will fail.

| Hook                      | What It Enforces                                                         |
| ------------------------- | ------------------------------------------------------------------------ |
| `enforce-branch-naming`   | Branch names must match the prefixes above                               |
| `enforce-commit-message`  | Commit messages must follow Conventional Commits                         |
| `detect-secrets`          | Blocks pushes containing leaked credentials (94 patterns, 40+ providers) |
| `enforce-max-file-size`   | No file larger than 10 MB                                                |
| `block-file-extensions`   | Rejects binary and secret file types (`.pem`, `.key`, `.p12`, etc.)      |
| `block-submodule-changes` | Submodules are prohibited                                                |

## Secrets

The `.env` file contains real credentials and is gitignored. Never commit it.
Never use `git add -f .env` or equivalent — the `detect-secrets` hook will
block it anyway. See `.env.example` for the full variable reference.
