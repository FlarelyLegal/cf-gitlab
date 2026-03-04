#!/opt/gitlab/embedded/bin/ruby
# encoding: utf-8
# frozen_string_literal: true

# ─── GitLab File Hook: Admin Privilege Discord Alert ─────────────────────────
# Posts a Discord notification when a user is granted admin privileges.
# Event: user_update_for_admin (admin flag changed to true)
#
# Reads DISCORD_WEBHOOK_URL_ADMIN from /root/.secrets/gitlab.env.
# Exits silently if the env var is not set.
#
# Install:
#   cp notify-admin-granted.rb /opt/gitlab/embedded/service/gitlab-rails/file_hooks/
#   chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/notify-admin-granted.rb
#
# GitLab docs: https://docs.gitlab.com/ee/administration/file_hooks.html
# ─────────────────────────────────────────────────────────────────────────────

require 'json'
require 'net/http'
require 'uri'

# Load .env values
env_file = '/root/.secrets/gitlab.env'
if File.exist?(env_file)
  File.readlines(env_file, encoding: 'utf-8').each do |line|
    line = line.encode('UTF-8', invalid: :replace, undef: :replace).strip
    next if line.empty? || line.start_with?('#')
    key, value = line.split('=', 2)
    next unless key && value
    value = value.gsub(/\A\$?['"]|['"]\z/, '')
    ENV[key] = value
  end
end

DISCORD_WEBHOOK_URL = ENV['DISCORD_WEBHOOK_URL_ADMIN']
LOG_FILE = '/var/log/gitlab/admin-audit.log'

def log(msg)
  File.open(LOG_FILE, 'a') { |f| f.puts "#{Time.now.utc.iso8601} [admin-grant] #{msg}" }
rescue StandardError
  # silently ignore log failures
end

begin
  args = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

event = args['event_name']

# Handle admin revocation (log only, no alert)
if event == 'user_update_for_admin' && [false, 'false'].include?(args['admin'])
  log "Admin REVOKED: user=#{args['username']} email=#{args['email']} id=#{args['user_id']}"
  exit 0
end

# Only alert on admin grants
exit 0 unless event == 'user_update_for_admin' && [true, 'true'].include?(args['admin'])

username = args['username'] || 'unknown'
name     = args['name'] || 'Unknown'
email    = args['email'] || 'unknown'
user_id  = args['user_id'] || '?'

log "Admin GRANTED: user=#{username} email=#{email} id=#{user_id}"

exit 0 if DISCORD_WEBHOOK_URL.nil? || DISCORD_WEBHOOK_URL.empty?

embed = {
  title: ':shield: Admin Privileges Granted',
  color: 16_711_680, # red
  fields: [
    { name: 'Username', value: username.to_s, inline: true },
    { name: 'Name',     value: name.to_s,     inline: true },
    { name: 'Email',    value: email.to_s,     inline: true },
    { name: 'User ID',  value: user_id.to_s,   inline: true }
  ],
  timestamp: Time.now.utc.iso8601
}

payload = {
  username: 'GitLab Security',
  embeds: [embed]
}.to_json

uri = URI(DISCORD_WEBHOOK_URL)
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true
http.open_timeout = 5
http.read_timeout = 5

request = Net::HTTP::Post.new(uri.request_uri)
request['Content-Type'] = 'application/json'
request.body = payload

http.request(request)
