#!/opt/gitlab/embedded/bin/ruby
# frozen_string_literal: true

# ─── GitLab File Hook: Admin Notifications ───────────────────────────────────
# Sends an email to the admin when key events occur:
#   - project_create:    New project created
#   - group_create:      New group created
#   - user_create:       New user account created
#   - user_add_to_team:  User added to a project
#
# Reads ADMIN_EMAIL and FROM_EMAIL from /root/.secrets/gitlab.env
# (GITLAB_ROOT_EMAIL and gitlab_email_from derived from CERT_EMAIL).
#
# Install:
#   cp notify-admin.rb /opt/gitlab/embedded/service/gitlab-rails/file_hooks/
#   chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/notify-admin.rb
#
# GitLab docs: https://docs.gitlab.com/ee/administration/file_hooks.html
# ──────────────────────────────────────────────────────────────────────────────

require 'json'
require 'mail'

# Load .env values
env_file = '/root/.secrets/gitlab.env'
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')
    key, value = line.split('=', 2)
    next unless key && value
    # Remove shell quoting ($'...' or "..." or '...')
    value = value.gsub(/\A\$?['"]|['"]\z/, '')
    ENV[key] = value
  end
end

ADMIN_EMAIL = ENV.fetch('GITLAB_ROOT_EMAIL', 'admin@example.com')
FROM_EMAIL  = ENV.fetch('CERT_EMAIL', ADMIN_EMAIL)

WATCHED_EVENTS = %w[
  project_create
  group_create
  user_create
  user_add_to_team
].freeze

begin
  args = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

event = args['event_name']
exit 0 unless WATCHED_EVENTS.include?(event)

subject, body = case event
when 'project_create'
  [
    "GitLab: New project \"#{args['name']}\"",
    "#{args['owner_name']} (#{args['owner_email']}) created project \"#{args['name']}\" " \
    "in namespace #{args['path_with_namespace']}."
  ]
when 'group_create'
  [
    "GitLab: New group \"#{args['name']}\"",
    "Group \"#{args['name']}\" created (path: #{args['path']}).\n" \
    "Owner: #{args['owner_name']} (#{args['owner_email']})."
  ]
when 'user_create'
  [
    "GitLab: New user \"#{args['username']}\"",
    "User #{args['name']} (#{args['email']}) created.\n" \
    "Username: #{args['username']}."
  ]
when 'user_add_to_team'
  [
    "GitLab: User added to #{args['project_path']}",
    "#{args['user_name']} (#{args['user_email']}) was added to " \
    "#{args['project_path']} with #{args['project_access']} access."
  ]
else
  exit 0
end

Mail.deliver do
  from    FROM_EMAIL
  to      ADMIN_EMAIL
  subject subject
  body    body
end
