#!/opt/gitlab/embedded/bin/ruby
# frozen_string_literal: true

# ��── GitLab File Hook: Failed Login Discord Alert ────────────────────────────
# Posts a Discord notification when a blocked user attempts to sign in.
# Event: user_failed_login
#
# Reads DISCORD_WEBHOOK_URL_FAILEDLOGIN from /root/.secrets/gitlab.env.
# Exits silently if the env var is not set.
#
# Install:
#   cp discord-failed-login.rb /opt/gitlab/embedded/service/gitlab-rails/file_hooks/
#   chmod +x /opt/gitlab/embedded/service/gitlab-rails/file_hooks/discord-failed-login.rb
#
# GitLab docs: https://docs.gitlab.com/ee/administration/file_hooks.html
# ─────────────────────────────────────────────────────────────────────────────

require 'json'
require 'net/http'
require 'uri'

# Load .env values
env_file = '/root/.secrets/gitlab.env'
if File.exist?(env_file)
  File.readlines(env_file).each do |line|
    line.strip!
    next if line.empty? || line.start_with?('#')
    key, value = line.split('=', 2)
    next unless key && value
    value = value.gsub(/\A\$?['"]|['"]\z/, '')
    ENV[key] = value
  end
end

DISCORD_WEBHOOK_URL = ENV['DISCORD_WEBHOOK_URL_FAILEDLOGIN']
exit 0 if DISCORD_WEBHOOK_URL.nil? || DISCORD_WEBHOOK_URL.empty?

begin
  args = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

exit 0 unless args['event_name'] == 'user_failed_login'

username = args['username'] || 'unknown'
name     = args['name'] || 'Unknown'
email    = args['email'] || 'unknown'
state    = args['state'] || 'unknown'

embed = {
  title: ':warning: Failed Login Attempt',
  color: 15_158_332, # red
  fields: [
    { name: 'Username', value: username, inline: true },
    { name: 'Name',     value: name,     inline: true },
    { name: 'Email',    value: email,    inline: true },
    { name: 'State',    value: state,    inline: true }
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
