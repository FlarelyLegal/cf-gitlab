[root](../README.md) / [hooks](README.md) / **install**

# Installing Hooks

Server hooks and file hooks for push policy enforcement and event notifications.
See [`README.md`](README.md) for full details on what each hook does.

## Server Hooks

Synchronous hooks that can reject pushes:

```bash
# On the GitLab LXC:
mkdir -p /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d
scp hooks/enforce-branch-naming hooks/block-file-extensions \
    hooks/enforce-commit-message hooks/detect-secrets \
    root@<LXC_IP>:/var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/
ssh root@<LXC_IP> 'chmod +x /var/opt/gitlab/gitaly/custom_hooks/pre-receive.d/* && \
    chown -R git:git /var/opt/gitlab/gitaly/custom_hooks'
```

> Requires `gitaly['configuration'] = { hooks: { custom_hooks_dir: '/var/opt/gitlab/gitaly/custom_hooks' } }`
> in `gitlab.rb` + `gitlab-ctl reconfigure`. Hooks are global (apply to all repos).

## File Hooks

Asynchronous hooks that cannot block actions:

```bash
scp hooks/notify-admin.rb hooks/discord-failed-login.rb \
    root@<LXC_IP>:/opt/gitlab/embedded/service/gitlab-rails/file_hooks/
ssh root@<LXC_IP> 'chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/*.rb'
```

Validate with `gitlab-rake file_hooks:validate` on the LXC.
