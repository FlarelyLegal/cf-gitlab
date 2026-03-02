[← Back to root](../README.md)

# Optional File Hooks

[GitLab file hooks](https://docs.gitlab.com/administration/file_hooks/) are server-side scripts that run automatically on system events. They are placed in `/opt/gitlab/embedded/service/gitlab-rails/file_hooks/` and picked up without a restart.

These hooks are **optional** and not required for core GitLab functionality.

## Hooks

| File                      | Event                                                       | Action                                                     |
| ------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------- |
| `notify-admin.rb`         | project_create, group_create, user_create, user_add_to_team | Emails the admin via GitLab's configured SMTP              |
| `discord-failed-login.rb` | user_failed_login                                           | Posts a Discord embed when a blocked user tries to sign in |

## Installation

```bash
# Copy to the file hooks directory
cp optional/<hook>.rb /opt/gitlab/embedded/service/gitlab-rails/file_hooks/
chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/<hook>.rb

# Validate
gitlab-rake file_hooks:validate
```

## Configuration

Both hooks read from `/root/.secrets/gitlab.env`:

| Hook                      | Required env vars                 |
| ------------------------- | --------------------------------- |
| `notify-admin.rb`         | `GITLAB_ROOT_EMAIL`, `CERT_EMAIL` |
| `discord-failed-login.rb` | `DISCORD_WEBHOOK_URL_FAILEDLOGIN` |

`discord-failed-login.rb` exits silently if its env var is not set.
