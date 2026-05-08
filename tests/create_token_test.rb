# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'openssl'
require 'tmpdir'

require_relative '../src/scripts/create_token'

class FakeGitHubClient
  attr_reader :calls

  def initialize(repo_installation:, access_token:)
    @repo_installation = repo_installation
    @access_token = access_token
    @calls = []
  end

  def request(method, request_path, auth_token:, body: nil)
    @calls << {
      method: method,
      path: request_path,
      auth_token: auth_token,
      body: body
    }

    return @repo_installation if request_path == '/repos/octo-org/repo-a/installation'
    return @access_token if request_path.end_with?('/access_tokens')

    raise GitHubAppToken::GitHubApiError, 'not found'
  end
end

class CreateTokenTest < Minitest::Test
  def setup
    @private_key_pem = OpenSSL::PKey::RSA.generate(2048).to_pem
    @repo_installation = JSON.parse(File.read(File.join(__dir__, 'fixtures/responses/repo-installation.json')))
    @access_token = JSON.parse(File.read(File.join(__dir__, 'fixtures/responses/access-token.json')))
  end

  def test_normalizes_raw_escaped_newline_and_base64_private_keys
    expected = @private_key_pem.end_with?("\n") ? @private_key_pem : "#{@private_key_pem}\n"

    assert_equal expected, GitHubAppToken.normalize_private_key(@private_key_pem)
    assert_equal expected, GitHubAppToken.normalize_private_key(@private_key_pem.gsub("\n", '\\n'))
    assert_equal expected, GitHubAppToken.normalize_private_key(Base64.strict_encode64(@private_key_pem),
                                                               base64: true)
  end

  def test_uses_app_id_parameter_and_skips_lookup_when_installation_id_is_explicit
    runtime = temp_runtime
    client = fake_client

    GitHubAppToken.create_token(base_options(output_json: runtime[:output_json]),
                                env: env_with_private_key(runtime),
                                client: client,
                                now: Time.utc(2026, 5, 8))

    assert_equal 1, client.calls.length
    assert_equal '/app/installations/123456/access_tokens', client.calls.first[:path]
    assert_equal '12345', jwt_payload(client.calls.first[:auth_token])['iss']
  end

  def test_uses_app_id_env_var_when_app_id_is_empty
    runtime = temp_runtime
    client = fake_client

    GitHubAppToken.create_token(base_options(app_id: '', app_id_env_var: 'APP_ID',
                                             output_json: runtime[:output_json]),
                                env: env_with_private_key(runtime).merge('APP_ID' => '67890'),
                                client: client,
                                now: Time.utc(2026, 5, 8))

    assert_equal '67890', jwt_payload(client.calls.first[:auth_token])['iss']
  end

  def test_looks_up_installation_id_from_the_repository_when_not_explicit
    runtime = temp_runtime
    client = fake_client

    GitHubAppToken.create_token(base_options(installation_id: '', output_json: runtime[:output_json]),
                                env: env_with_private_key(runtime),
                                client: client,
                                now: Time.utc(2026, 5, 8))

    assert_equal 2, client.calls.length
    assert_equal '/repos/octo-org/repo-a/installation', client.calls[0][:path]
    assert_equal '/app/installations/123456/access_tokens', client.calls[1][:path]
  end

  def test_validates_permissions_json
    assert_equal({ 'contents' => 'write' }, GitHubAppToken.parse_permissions('{"contents":"write"}'))
    assert_raises(GitHubAppToken::InputError) { GitHubAppToken.parse_permissions('[]') }
    assert_raises(GitHubAppToken::InputError) { GitHubAppToken.parse_permissions('{') }
  end

  def test_rejects_repositories_and_repository_ids_together
    runtime = temp_runtime

    error = assert_raises(GitHubAppToken::InputError) do
      GitHubAppToken.create_token(base_options(repositories: 'repo-a', repository_ids: '1',
                                               output_json: runtime[:output_json]),
                                  env: env_with_private_key(runtime),
                                  client: fake_client)
    end
    assert_match(/cannot be used together/, error.message)
  end

  def test_omits_token_from_output_json_by_default_and_exports_it_through_bash_env
    runtime = temp_runtime

    GitHubAppToken.create_token(base_options(output_json: runtime[:output_json]),
                                env: env_with_private_key(runtime),
                                client: fake_client,
                                now: Time.utc(2026, 5, 8))

    output = JSON.parse(File.read(runtime[:output_json]))
    assert_nil output['token']
    assert_equal 'GH_APP_TOKEN', output['token_exported_to']
    assert_equal 123456, output['installation_id']
    assert_match(/export GH_APP_TOKEN='ghs_example_token'/, File.read(runtime[:bash_env]))
  end

  def test_redacts_private_key_and_token_values_from_errors
    message = GitHubAppToken.redact("failed with #{@private_key_pem} and ghs_example_token",
                                    [@private_key_pem, 'ghs_example_token'])

    refute_match(/BEGIN RSA PRIVATE KEY/, message)
    refute_match(/ghs_example_token/, message)
    assert_match(/\[REDACTED\]/, message)
  end

  private

  def base_options(overrides = {})
    {
      app_id: '12345',
      app_id_env_var: 'GITHUB_APP_ID',
      private_key_env_var: 'GITHUB_APP_PRIVATE_KEY',
      private_key_base64: false,
      installation_id: '123456',
      installation_id_env_var: 'GITHUB_APP_INSTALLATION_ID',
      owner: 'octo-org',
      repo: 'repo-a',
      installation_lookup: 'repo',
      repositories: '',
      repository_ids: '',
      permissions: '',
      github_api_url: 'https://api.github.com',
      github_api_version: '2026-03-10',
      token_env_var: 'GH_APP_TOKEN',
      export_env_prefix: 'GH_APP',
      output_json: '/tmp/github-app-token-result.json',
      include_token_in_output_json: false
    }.merge(overrides)
  end

  def env_with_private_key(runtime)
    {
      'BASH_ENV' => runtime[:bash_env],
      'GITHUB_APP_PRIVATE_KEY' => @private_key_pem
    }
  end

  def fake_client
    FakeGitHubClient.new(repo_installation: @repo_installation, access_token: @access_token)
  end

  def temp_runtime
    directory = Dir.mktmpdir('github-app-token-test-')
    {
      directory: directory,
      bash_env: File.join(directory, 'bash_env'),
      output_json: File.join(directory, 'result.json')
    }
  end

  def jwt_payload(token)
    payload = token.split('.')[1]
    padded = payload.ljust((payload.length + 3) / 4 * 4, '=')
    JSON.parse(Base64.urlsafe_decode64(padded))
  end
end
