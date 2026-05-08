#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'openssl'
require 'time'
require 'uri'

module GitHubAppToken
  RUNTIME_PREFIX = 'GITHUB_APP_TOKEN_'
  ENV_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  INSTALLATION_LOOKUPS = %w[repo org user app-list none].freeze

  class InputError < StandardError; end
  class GitHubApiError < StandardError; end

  class GitHubClient
    def initialize(api_url:, api_version:)
      @api_url = api_url
      @api_version = api_version
    end

    def request(method, request_path, auth_token:, body: nil)
      uri = URI(api_url_with_path(request_path))
      request = build_request(method, uri, auth_token, body)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.request(request)
      end

      data = GitHubAppToken.parse_json_body(response.body)
      return data if response.is_a?(Net::HTTPSuccess)

      detail = data['message'] ? ": #{data['message']}" : ''
      raise GitHubApiError, "GitHub API #{method} #{request_path} failed with #{response.code}#{detail}"
    end

    private

    def api_url_with_path(request_path)
      "#{@api_url.sub(%r{/+\z}, '')}/#{request_path.sub(%r{\A/+}, '')}"
    end

    def build_request(method, uri, auth_token, body)
      klass = {
        'GET' => Net::HTTP::Get,
        'POST' => Net::HTTP::Post
      }.fetch(method) { raise InputError, "Unsupported GitHub API method: #{method}" }

      request = klass.new(uri)
      request['Accept'] = 'application/vnd.github+json'
      request['Authorization'] = "Bearer #{auth_token}"
      request['Content-Type'] = 'application/json'
      request['X-GitHub-Api-Version'] = @api_version
      request.body = JSON.generate(body) unless body.nil?
      request
    end
  end

  module_function

  def parse_boolean(value, default_value = false)
    return default_value if value.nil? || value == ''
    return value if value == true || value == false

    normalized = value.to_s.strip.downcase
    return true if %w[true 1 yes y].include?(normalized)
    return false if %w[false 0 no n].include?(normalized)

    raise InputError, "Invalid boolean value: #{value}"
  end

  def expand_env_reference(value, env = ENV)
    return value unless value.is_a?(String)

    value.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
      env[Regexp.last_match(1) || Regexp.last_match(2)] || ''
    end
  end

  def runtime_value(env, name, fallback = '')
    expand_env_reference(env.fetch("#{RUNTIME_PREFIX}#{name}", fallback), env)
  end

  def read_runtime_options(env = ENV)
    {
      app_id: runtime_value(env, 'APP_ID'),
      app_id_env_var: runtime_value(env, 'APP_ID_ENV_VAR', 'GITHUB_APP_ID'),
      private_key_env_var: runtime_value(env, 'PRIVATE_KEY_ENV_VAR', 'GITHUB_APP_PRIVATE_KEY'),
      private_key_base64: parse_boolean(runtime_value(env, 'PRIVATE_KEY_BASE64', 'false')),
      installation_id: runtime_value(env, 'INSTALLATION_ID'),
      installation_id_env_var: runtime_value(env, 'INSTALLATION_ID_ENV_VAR', 'GITHUB_APP_INSTALLATION_ID'),
      owner: runtime_value(env, 'OWNER', '${CIRCLE_PROJECT_USERNAME}'),
      repo: runtime_value(env, 'REPO', '${CIRCLE_PROJECT_REPONAME}'),
      installation_lookup: runtime_value(env, 'INSTALLATION_LOOKUP', 'repo'),
      repositories: runtime_value(env, 'REPOSITORIES'),
      repository_ids: runtime_value(env, 'REPOSITORY_IDS'),
      permissions: runtime_value(env, 'PERMISSIONS'),
      github_api_url: runtime_value(env, 'GITHUB_API_URL', 'https://api.github.com'),
      github_api_version: runtime_value(env, 'GITHUB_API_VERSION', '2026-03-10'),
      token_env_var: runtime_value(env, 'TOKEN_ENV_VAR', 'GH_APP_TOKEN'),
      export_env_prefix: runtime_value(env, 'EXPORT_ENV_PREFIX', 'GH_APP'),
      output_json: runtime_value(env, 'OUTPUT_JSON', '/tmp/github-app-token-result.json'),
      include_token_in_output_json: parse_boolean(runtime_value(env, 'INCLUDE_TOKEN_IN_OUTPUT_JSON', 'false'))
    }
  end

  def normalize_private_key(raw_value, base64: false)
    raise InputError, 'GitHub App private key is empty.' if raw_value.to_s.strip.empty?

    private_key = raw_value.to_s.strip
    private_key = Base64.decode64(private_key.gsub(/\s+/, '')).strip if base64
    private_key = private_key.gsub('\\n', "\n").strip

    has_header = private_key.match?(/-----BEGIN (?:RSA )?PRIVATE KEY-----/)
    has_footer = private_key.match?(/-----END (?:RSA )?PRIVATE KEY-----/)
    raise InputError, 'GitHub App private key must be a PEM private key.' unless has_header && has_footer

    private_key.end_with?("\n") ? private_key : "#{private_key}\n"
  end

  def validate_env_name(value, label)
    return if value.to_s.match?(ENV_NAME_PATTERN)

    raise InputError, "#{label} must be a valid environment variable name."
  end

  def clean(value)
    value.to_s.strip
  end

  def parse_comma_list(value)
    clean(value).empty? ? [] : clean(value).split(',').map(&:strip).reject(&:empty?)
  end

  def parse_repository_ids(value)
    parse_comma_list(value).map do |item|
      raise InputError, 'repository_ids must contain only numeric IDs.' unless item.match?(/\A\d+\z/)

      item.to_i
    end
  end

  def parse_permissions(value)
    return nil if clean(value).empty?

    parsed = JSON.parse(value)
    raise InputError, 'permissions must be a JSON object.' unless parsed.is_a?(Hash)

    parsed
  rescue JSON::ParserError => e
    raise InputError, "permissions must be a valid JSON object: #{e.message}"
  end

  def create_app_jwt(app_id:, private_key:, now: Time.now)
    now_seconds = now.to_i
    header = base64url(JSON.generate({ alg: 'RS256', typ: 'JWT' }))
    payload = base64url(JSON.generate({ iat: now_seconds - 60, exp: now_seconds + 540, iss: app_id }))
    body = "#{header}.#{payload}"
    key = OpenSSL::PKey.read(private_key)
    signature = base64url(key.sign(OpenSSL::Digest.new('SHA256'), body))
    "#{body}.#{signature}"
  end

  def lookup_installation_id(options:, jwt:, client:)
    owner = clean(options[:owner])
    repo = clean(options[:repo])

    case options[:installation_lookup]
    when 'repo'
      raise InputError, 'owner and repo are required for repo installation lookup.' if owner.empty? || repo.empty?

      data = client.request('GET', "/repos/#{encode_path_part(owner)}/#{encode_path_part(repo)}/installation",
                            auth_token: jwt)
      clean(data['id'])
    when 'org', 'user'
      raise InputError, "owner is required for #{options[:installation_lookup]} installation lookup." if owner.empty?

      segment = options[:installation_lookup] == 'org' ? 'orgs' : 'users'
      data = client.request('GET', "/#{segment}/#{encode_path_part(owner)}/installation", auth_token: jwt)
      clean(data['id'])
    when 'app-list'
      raise InputError, 'owner is required for app-list installation lookup.' if owner.empty?

      data = client.request('GET', '/app/installations', auth_token: jwt)
      installations = data.is_a?(Array) ? data : data.fetch('installations', [])
      match = installations.find do |installation|
        installation.dig('account', 'login').to_s.downcase == owner.downcase
      end
      raise InputError, "No GitHub App installation found for #{owner}." unless match

      clean(match['id'])
    else
      raise InputError, 'installation_id is required when installation_lookup is none.'
    end
  end

  def build_access_token_body(repositories:, repository_ids:, permissions:)
    body = {}
    body[:repositories] = repositories unless repositories.empty?
    body[:repository_ids] = repository_ids unless repository_ids.empty?
    body[:permissions] = permissions unless permissions.nil?
    body.empty? ? nil : body
  end

  def create_token(options, env: ENV, client: nil, now: Time.now)
    validate_options(options)

    app_id = clean(options[:app_id])
    app_id = clean(env[options[:app_id_env_var]]) if app_id.empty?
    raise InputError, 'GitHub App ID is required through app_id or app_id_env_var.' if app_id.empty?

    private_key = normalize_private_key(env[options[:private_key_env_var]],
                                        base64: options[:private_key_base64])
    explicit_installation_id = clean(options[:installation_id])
    explicit_installation_id = clean(env[options[:installation_id_env_var]]) if explicit_installation_id.empty?
    repositories = parse_comma_list(options[:repositories])
    repository_ids = parse_repository_ids(options[:repository_ids])
    permissions = parse_permissions(options[:permissions])

    unless repositories.empty? || repository_ids.empty?
      raise InputError, 'repositories and repository_ids cannot be used together.'
    end

    client ||= GitHubClient.new(api_url: options[:github_api_url], api_version: options[:github_api_version])
    jwt = create_app_jwt(app_id: app_id, private_key: private_key, now: now)
    installation_id = explicit_installation_id
    installation_id = lookup_installation_id(options: options, jwt: jwt, client: client) if installation_id.empty?

    token_response = client.request(
      'POST',
      "/app/installations/#{encode_path_part(installation_id)}/access_tokens",
      auth_token: jwt,
      body: build_access_token_body(repositories: repositories, repository_ids: repository_ids,
                                    permissions: permissions)
    )
    raise GitHubApiError, 'GitHub access token response did not include a token.' if token_response['token'].to_s.empty?

    metadata = build_metadata(token_response, installation_id, repositories, options[:token_env_var])
    metadata[:token] = token_response['token'] if options[:include_token_in_output_json]

    write_output_json(options[:output_json], metadata)
    write_bash_env(env['BASH_ENV'], options[:token_env_var], options[:export_env_prefix], options[:output_json],
                   token_response, installation_id)
    metadata
  end

  def redact(text, secrets)
    secrets.compact.uniq.select { |secret| secret.is_a?(String) && secret.length >= 4 }.sort_by { |s| -s.length }
           .reduce(text.to_s) { |message, secret| message.gsub(secret, '[REDACTED]') }
  end

  def parse_json_body(body)
    return {} if body.to_s.empty?

    JSON.parse(body)
  end

  def validate_options(options)
    validate_env_name(options[:app_id_env_var], 'app_id_env_var')
    validate_env_name(options[:private_key_env_var], 'private_key_env_var')
    validate_env_name(options[:installation_id_env_var], 'installation_id_env_var')
    validate_env_name(options[:token_env_var], 'token_env_var')
    validate_env_name(options[:export_env_prefix], 'export_env_prefix')

    return if INSTALLATION_LOOKUPS.include?(options[:installation_lookup])

    raise InputError, 'installation_lookup must be repo, org, user, app-list, or none.'
  end

  def build_metadata(token_response, installation_id, requested_repositories, token_env_var)
    repositories = if token_response['repositories'].is_a?(Array)
                     token_response['repositories'].filter_map { |repository| repository['name'] }
                   else
                     requested_repositories
                   end

    {
      installation_id: integer_or_string(installation_id),
      expires_at: token_response['expires_at'],
      repository_selection: token_response['repository_selection'],
      permissions: token_response['permissions'] || {},
      repositories: repositories,
      token_exported_to: token_env_var
    }
  end

  def write_output_json(output_json, metadata)
    FileUtils.mkdir_p(File.dirname(output_json))
    File.write(output_json, "#{JSON.pretty_generate(metadata)}\n", mode: 'w', perm: 0o600)
    File.chmod(0o600, output_json)
  end

  def write_bash_env(bash_env_path, token_env_var, export_env_prefix, output_json, token_response, installation_id)
    raise InputError, 'BASH_ENV is not set; CircleCI needs it to export values for later steps.' if bash_env_path.to_s.empty?

    FileUtils.mkdir_p(File.dirname(bash_env_path))
    lines = [
      "export #{token_env_var}=#{shell_quote(token_response['token'])}",
      "export #{export_env_prefix}_INSTALLATION_ID=#{shell_quote(installation_id)}",
      "export #{export_env_prefix}_EXPIRES_AT=#{shell_quote(token_response['expires_at'])}",
      "export #{export_env_prefix}_OUTPUT_JSON=#{shell_quote(output_json)}"
    ]
    File.open(bash_env_path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.write("#{lines.join("\n")}\n")
    end
  end

  def shell_quote(value)
    "'#{value.to_s.gsub("'", "'\\\\''")}'"
  end

  def base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  def encode_path_part(value)
    URI.encode_www_form_component(value.to_s).gsub('%2F', '/')
  end

  def integer_or_string(value)
    value.to_s.match?(/\A\d+\z/) ? value.to_i : value
  end
end

if __FILE__ == $PROGRAM_NAME
  options = nil
  begin
    options = GitHubAppToken.read_runtime_options(ENV)
    metadata = GitHubAppToken.create_token(options)
    puts "GitHub App installation token exported to #{metadata[:token_exported_to]}; " \
         "metadata written to #{options[:output_json]}."
  rescue StandardError => e
    private_key = options && ENV[options[:private_key_env_var]]
    warn GitHubAppToken.redact("#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}", [private_key])
    exit 1
  end
end
