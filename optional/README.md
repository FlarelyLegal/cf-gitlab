[root](../README.md) / **optional**

# Optional Hooks

These hooks are **optional** and not required for core GitLab functionality.

## File Hooks

[File hooks](https://docs.gitlab.com/administration/file_hooks/) run asynchronously via Sidekiq on system events. They cannot block actions.

| File                      | Event                                                       | Action                                                     |
| ------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------- |
| `notify-admin.rb`         | project_create, group_create, user_create, user_add_to_team | Emails the admin via GitLab's configured SMTP              |
| `discord-failed-login.rb` | user_failed_login                                           | Posts a Discord embed when a blocked user tries to sign in |

```bash
# Install
cp optional/<hook>.rb /opt/gitlab/embedded/service/gitlab-rails/file_hooks/
chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/<hook>.rb

# Validate
gitlab-rake file_hooks:validate
```

Both hooks read from `/root/.secrets/gitlab.env`:

| Hook                      | Required env vars                 |
| ------------------------- | --------------------------------- |
| `notify-admin.rb`         | `GITLAB_ROOT_EMAIL`, `CERT_EMAIL` |
| `discord-failed-login.rb` | `DISCORD_WEBHOOK_URL_FAILEDLOGIN` |

`discord-failed-login.rb` exits silently if its env var is not set.

## Server Hooks

[Server hooks](https://docs.gitlab.com/administration/server_hooks.html) run synchronously during git operations and can **reject pushes**. They are placed in the Gitaly custom hooks directory.

> **Important**: GitLab 16+ requires hooks in `/var/opt/gitlab/gitaly/custom_hooks/`, not the legacy `gitlab-rails` path. You must also set the directory in `gitlab.rb`:
>
> ```ruby
> gitaly['configuration'] = {
>   hooks: { custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks' }
> }
> ```
>
> Then run `gitlab-ctl reconfigure`.

| File                     | Type        | Action                                                                                              |
| ------------------------ | ----------- | --------------------------------------------------------------------------------------------------- |
| `enforce-branch-naming`  | pre-receive | Rejects branches not matching `feature/`, `fix/`, `hotfix/`, `release/`, `chore/`, `docs/`          |
| `block-file-extensions`  | pre-receive | Rejects pushes containing binaries, archives, secrets (.exe, .zip, .jar, .pem, etc.)                |
| `enforce-commit-message` | pre-receive | Requires Conventional Commits (`feat:`, `fix:`, `docs:`, etc.). Merge commits exempt.               |
| `detect-secrets`         | pre-receive | Scans diffs for 94 secret patterns (API keys, private keys, tokens, connection strings). See below. |

Edit the arrays/patterns at the top of each script to customize. `enforce-branch-naming` exempts `main` and `master`.

```bash
# Install (global, all repos)
mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d
cp optional/enforce-branch-naming optional/block-file-extensions \
   optional/enforce-commit-message optional/detect-secrets \
   /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/
chmod +x /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/*
chown -R git:git /var/opt/gitlab/gitaly/custom_hooks
```

### detect-secrets

Secret Push Protection for GitLab CE. Scans only the diff (added lines) for high-confidence patterns, covering 40+ providers:

| Category           | Providers                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------- |
| Private keys       | RSA, DSA, EC, OpenSSH, PGP, PKCS8                                                                  |
| Cloud providers    | AWS, GCP/Firebase, Azure, Cloudflare (current + new scannable format), DigitalOcean                |
| AI providers       | OpenAI, Anthropic, Hugging Face, Replicate, Groq                                                   |
| Git platforms      | GitHub (PAT, OAuth, fine-grained, app), GitLab (PAT, runner, deploy, trigger, 8 more)              |
| Communication      | Slack (bot, user, app, webhook, config), Discord (bot, webhook), Telegram                          |
| Payment            | Stripe (live secret, restricted, publishable)                                                      |
| Infrastructure     | HashiCorp Vault/Terraform, Doppler, Pulumi, PlanetScale, Supabase, Grafana, Sentry                 |
| Package registries | npm, PyPI, RubyGems, Docker                                                                        |
| Email/messaging    | SendGrid, Mailgun, Twilio                                                                          |
| Other              | Heroku, Postman, Linear, Shopify, Twitch, Twitter/X                                                |
| Generic            | Database connection strings, passwords in URLs, env var assignments (PASSWORD, SECRET, TOKEN, etc) |

**Per-repo allowlist**: Add a `.secret-detection-allowlist` file to a repository (one regex per line, `#` for comments) to suppress known false positives.

**Skipped files**: Lock files, minified JS/CSS, test fixtures, `.env.example`/`.env.sample`/`.env.template`.
