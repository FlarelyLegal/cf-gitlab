[← Back to root](../README.md)

# Optional File Hooks

[GitLab file hooks](https://docs.gitlab.com/administration/file_hooks/) are server-side scripts that run automatically on system events. They are placed in `/opt/gitlab/embedded/service/gitlab-rails/file_hooks/` and picked up without a restart.

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

[Server hooks](https://docs.gitlab.com/administration/server_hooks.html) run synchronously during git operations and can **reject pushes**.

| File                     | Type        | Action                                                                                     |
| ------------------------ | ----------- | ------------------------------------------------------------------------------------------ |
| `enforce-branch-naming`  | pre-receive | Rejects branches not matching `feature/`, `fix/`, `hotfix/`, `release/`, `chore/`, `docs/` |
| `block-file-extensions`  | pre-receive | Rejects pushes containing binaries, archives, secrets (.exe, .zip, .jar, .pem, etc.)       |
| `enforce-commit-message` | pre-receive | Requires Conventional Commits (`feat:`, `fix:`, `docs:`, etc.). Merge commits exempt.      |

Edit the arrays/patterns at the top of each script to customize. `enforce-branch-naming` exempts `main` and `master`.

```bash
# Install (global, all repos)
mkdir -p /opt/gitlab/embedded/service/gitlab-rails/custom_hooks/pre-receive.d
cp optional/enforce-branch-naming optional/block-file-extensions optional/enforce-commit-message \
  /opt/gitlab/embedded/service/gitlab-rails/custom_hooks/pre-receive.d/
chmod +x /opt/gitlab/embedded/service/gitlab-rails/custom_hooks/pre-receive.d/*
```
