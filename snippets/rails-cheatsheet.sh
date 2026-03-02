# shellcheck disable=all
# ─── GitLab Rails Console Cheatsheet ─────────────────────────────
# This file contains Ruby snippets (not shell) — run via:
#   gitlab-rails runner <script.rb>
#   gitlab-rails console

# ─── List all admin users ────────────────────────────────────────
User.where(admin: true).each { |u| puts "#{u.username} (#{u.email})" }

# ─── Reset a user password ──────────────────────────────────────
user = User.find_by(username: "tim")
user.password = user.password_confirmation = "NewSecurePassword123"
user.save!

# ─── Confirm an email without SMTP ──────────────────────────────
# Via gitlab-psql:
#   gitlab-psql -d gitlabhq_production -c \
#     "UPDATE emails SET confirmed_at = NOW() WHERE email = 'user@example.com';"

# ─── List all runners ───────────────────────────────────────────
Ci::Runner.all.each { |r| puts "##{r.id} #{r.description} (#{r.runner_type})" }

# ─── Create an instance runner ──────────────────────────────────
runner = Ci::Runner.create!(
  runner_type: :instance_type,
  description: "my-runner",
  active: true,
  run_untagged: true
)
puts runner.token

# ─── List all projects ──────────────────────────────────────────
Project.all.each { |p| puts "#{p.full_path} (#{p.visibility})" }

# ─── List all groups ────────────────────────────────────────────
Group.all.each { |g| puts "#{g.full_path} (#{g.visibility})" }
