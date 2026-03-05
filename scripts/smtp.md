[root](../README.md) / [scripts](README.md) / **smtp**

# SMTP Configuration

Without SMTP, GitLab cannot send notification emails, password resets, or email verifications.
If you skip this, those actions must be done via the Rails console.

## Configure

Append the following to `/etc/gitlab/gitlab.rb` on the LXC (adjust values for your SMTP provider):

```ruby
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.example.com"
gitlab_rails['smtp_port'] = 587
gitlab_rails['smtp_user_name'] = "gitlab@example.com"
gitlab_rails['smtp_password'] = "<SMTP_PASSWORD>"
gitlab_rails['smtp_domain'] = "example.com"
gitlab_rails['smtp_authentication'] = "plain"
gitlab_rails['smtp_enable_starttls_auto'] = true

gitlab_rails['gitlab_email_from'] = "gitlab@example.com"
gitlab_rails['gitlab_email_reply_to'] = "gitlab@example.com"
gitlab_rails['gitlab_email_display_name'] = "GitLab"
```

Then reconfigure and send a test email:

```bash
gitlab-ctl reconfigure
gitlab-rails runner "Notify.test_email('you@example.com', 'GitLab SMTP Test', 'It works.').deliver_now"
```

> See [GitLab SMTP docs](https://docs.gitlab.com/omnibus/settings/smtp.html) for provider-specific
> examples (Gmail, SendGrid, Amazon SES, etc.).
