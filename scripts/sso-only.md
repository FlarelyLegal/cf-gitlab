[root](../README.md) / [scripts](README.md) / **sso-only**

# SSO-Only Lockdown

Disables manual signup and password login, and enables auto sign-in so users go straight
through the Cloudflare Access OIDC flow.

> **Do not run this until you've confirmed SSO works.** If you lock yourself out, you'll need
> Rails console access on the LXC to re-enable password login (see emergency access below).

## Usage

```bash
# Copy to LXC and dry-run first
scp scripts/sso-only.sh root@<LXC_IP>:/tmp/
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh --dry-run'

# Apply
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh'
```

## What Changes

- **Signup:** disabled -- no "Register" tab on the login page
- **Password login:** disabled -- no username/password fields
- **Auto sign-in:** enabled -- visitors are redirected straight to Cloudflare Access OIDC
  (no login page, no "click to sign in"). Since Access already has a session, login is instant.

Signup and password settings are application-level (stored in the database). Auto sign-in is a
`gitlab.rb` setting (the script runs `gitlab-ctl reconfigure` automatically). All persist across
upgrades.

## Revert

To re-enable signup + password login + remove auto sign-in:

```bash
ssh root@<LXC_IP> 'bash /tmp/sso-only.sh --revert'
```

## Bypass Auto Sign-in

To reach the manual login page without reverting:

```text
https://gitlab.example.com/users/sign_in?auto_sign_in=false
```

## Emergency Root Access

If SSO breaks and you need to re-enable password login:

```bash
ssh root@<LXC_IP>
gitlab-rails runner "Gitlab::CurrentSettings.current_application_settings.update!(password_authentication_enabled_for_web: true)"
# Then remove auto sign-in so the login page appears:
sed -i '/omniauth_auto_sign_in_with_provider/d' /etc/gitlab/gitlab.rb
gitlab-ctl reconfigure
```
