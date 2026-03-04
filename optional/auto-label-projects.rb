#!/opt/gitlab/embedded/bin/ruby
# encoding: utf-8
# frozen_string_literal: true

# GitLab File Hook: Auto-Label New Projects
# Creates industry standard labels on every new project.
# Event: project_create
# Reads GITLAB_API_TOKEN_HOOKS from /root/.secrets/gitlab.env.

require 'json'
require 'net/http'
require 'uri'

LOG_FILE = '/var/log/gitlab/auto-label.log'

def log(msg)
  File.open(LOG_FILE, 'a') { |f| f.puts "#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} [auto-label] #{msg}" }
rescue StandardError
  nil
end

# Load env
env_file = '/root/.secrets/gitlab.env'
if File.exist?(env_file)
  File.readlines(env_file, encoding: 'utf-8').each do |line|
    line = line.encode('UTF-8', invalid: :replace, undef: :replace).strip
    next if line.empty? || line.start_with?('#')
    key, value = line.split('=', 2)
    next unless key && value
    value = value.sub(/\A['"]/, '').sub(/['"]\z/, '')
    ENV[key] = value
  end
end

gitlab_url = ENV.fetch('GITLAB_URL', 'https://gitlab.flarelylegal.com')
api_token = ENV['GITLAB_API_TOKEN_HOOKS']

# Read event
begin
  event = JSON.parse($stdin.read)
rescue JSON::ParserError
  exit 0
end

exit 0 unless event['event_name'] == 'project_create'

project_id = event['project_id']
project_path = event['path_with_namespace'] || 'unknown'

unless project_id
  log 'ERROR: No project_id in event data'
  exit 0
end

if api_token.nil? || api_token.empty?
  log 'ERROR: GITLAB_API_TOKEN_HOOKS not set'
  exit 0
end

log "New project: id=#{project_id} path=#{project_path}"

labels = [
  ['type::bug',            '#CC0000', 'Bug report'],
  ['type::feature',        '#428BCA', 'New feature request or enhancement'],
  ['type::maintenance',    '#8E44AD', 'Technical debt, refactoring, or dependency updates'],
  ['type::documentation',  '#34495E', 'Documentation improvements or additions'],
  ['type::security',       '#D10069', 'Security vulnerability or hardening'],
  ['type::performance',    '#F39C12', 'Performance improvement or optimization'],
  ['priority::critical',   '#CC0000', 'Must be fixed immediately'],
  ['priority::high',       '#D9534F', 'Should be addressed in the current sprint'],
  ['priority::medium',     '#F0AD4E', 'Should be addressed soon'],
  ['priority::low',        '#5CB85C', 'Nice to have, can wait'],
  ['severity::1',          '#CC0000', 'Blocker - system unusable, data loss'],
  ['severity::2',          '#D9534F', 'Critical - major feature broken, no workaround'],
  ['severity::3',          '#F0AD4E', 'Major - feature impaired but workaround available'],
  ['severity::4',          '#5CB85C', 'Minor - cosmetic issue'],
  ['workflow::backlog',     '#E4E7ED', 'Not yet planned or prioritized'],
  ['workflow::ready',       '#428BCA', 'Groomed and ready for development'],
  ['workflow::in-progress', '#F0AD4E', 'Currently being worked on'],
  ['workflow::in-review',   '#8E44AD', 'In code review or MR open'],
  ['workflow::blocked',     '#CC0000', 'Blocked by dependency or decision'],
  ['workflow::done',        '#5CB85C', 'Completed and verified'],
  ['environment::production',  '#CC0000', 'Relates to production environment'],
  ['environment::staging',     '#F0AD4E', 'Relates to staging environment'],
  ['environment::development', '#428BCA', 'Relates to development environment'],
  ['good first issue',   '#7F8C8D', 'Good for newcomers or first-time contributors'],
  ['needs-triage',       '#F39C12', 'Needs to be triaged and prioritized'],
  ['breaking-change',    '#CC0000', 'Introduces a breaking change'],
  ['regression',         '#D9534F', 'Something that previously worked is now broken'],
  ['tech-debt',          '#8E44AD', 'Identified technical debt'],
  ['wontfix',            '#7F8C8D', 'Will not be addressed'],
  ['duplicate',          '#7F8C8D', 'Duplicate of another issue'],
  ['needs-discussion',   '#34495E', 'Requires team discussion before proceeding'],
  ['infrastructure',     '#1ABC9C', 'Related to infrastructure, CI/CD, or DevOps'],
  ['dependencies',       '#E67E22', 'Related to dependency updates or management']
]

created = 0
skipped = 0
failed = 0

labels.each do |name, color, description|
  uri = URI("#{gitlab_url}/api/v4/projects/#{project_id}/labels")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == 'https')
  http.open_timeout = 5
  http.read_timeout = 5

  req = Net::HTTP::Post.new(uri.request_uri)
  req['PRIVATE-TOKEN'] = api_token
  req['Content-Type'] = 'application/json'
  req.body = JSON.generate({ 'name' => name, 'color' => color, 'description' => description })

  begin
    resp = http.request(req)
    case resp.code.to_i
    when 201 then created += 1
    when 409 then skipped += 1
    else
      failed += 1
      log "WARN: Failed '#{name}' (HTTP #{resp.code}): #{resp.body[0..100]}"
    end
  rescue StandardError => e
    failed += 1
    log "ERROR: '#{name}': #{e.message}"
  end
end

log "Labels applied to project #{project_id} (#{project_path}): created=#{created} skipped=#{skipped} failed=#{failed}"
