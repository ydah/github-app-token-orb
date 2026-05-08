#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'uri'

module GitHubAppTokenGit
  ENV_NAME_PATTERN = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  module_function

  def run(env = ENV)
    token_env_var = expand_env_ref(env.fetch('GITHUB_APP_TOKEN_CONFIGURE_TOKEN_ENV_VAR', 'GH_APP_TOKEN'), env)
    repository = expand_env_ref(default_repository(env), env)
    git_remote = expand_env_ref(env.fetch('GITHUB_APP_TOKEN_CONFIGURE_GIT_REMOTE', 'origin'), env)
    github_web_url = expand_env_ref(env.fetch('GITHUB_APP_TOKEN_CONFIGURE_GITHUB_WEB_URL', 'https://github.com'), env)
    method = expand_env_ref(env.fetch('GITHUB_APP_TOKEN_CONFIGURE_METHOD', 'askpass'), env)

    fail_with('token_env_var must be a valid environment variable name.') unless token_env_var.match?(ENV_NAME_PATTERN)

    token_value = env[token_env_var].to_s
    fail_with("Token environment variable #{token_env_var} is empty.") if token_value.empty?
    fail_with('repository must use owner/repo format.') unless repository.match?(%r{\A[^/\s]+/[^/\s]+\z})
    fail_with('git_remote must not be empty.') if git_remote.empty?

    github_web_url = github_web_url.sub(%r{/+\z}, '')
    repository_url = "#{github_web_url}/#{repository}.git"

    case method
    when 'askpass'
      configure_askpass(token_env_var, git_remote, repository_url, env)
    when 'remote-url'
      configure_remote_url(token_value, git_remote, github_web_url, repository)
    else
      fail_with('method must be askpass or remote-url.')
    end

    puts "Git authentication configured for #{repository} using #{method}."
  end

  def expand_env_ref(value, env)
    value.to_s.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/) do
      env[Regexp.last_match(1) || Regexp.last_match(2)] || ''
    end
  end

  def default_repository(env)
    env.fetch('GITHUB_APP_TOKEN_CONFIGURE_REPOSITORY',
              "#{env.fetch('CIRCLE_PROJECT_USERNAME', '')}/#{env.fetch('CIRCLE_PROJECT_REPONAME', '')}")
  end

  def configure_askpass(token_env_var, git_remote, repository_url, env)
    askpass_file = File.join(env.fetch('TMPDIR', '/tmp'), "github-app-token-askpass-#{token_env_var}.sh")
    File.write(askpass_file, askpass_script)
    File.chmod(0o700, askpass_file)
    run_git('remote', 'set-url', git_remote, repository_url)
    run_git('config', '--local', 'core.askPass', askpass_file)
    run_git('config', '--local', 'credential.username', 'x-access-token')

    return if env['BASH_ENV'].to_s.empty?

    File.open(env['BASH_ENV'], File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
      file.write("export GIT_ASKPASS=#{shell_quote(askpass_file)}\n")
      file.write("export GITHUB_APP_TOKEN_ASKPASS_ENV_VAR=#{shell_quote(token_env_var)}\n")
    end
  end

  def askpass_script
    <<~SCRIPT
      #!/usr/bin/env sh
      case "$1" in
        *Username*) printf '%s\\n' "x-access-token" ;;
        *Password*) printenv "${GITHUB_APP_TOKEN_ASKPASS_ENV_VAR}" ;;
        *) printf '\\n' ;;
      esac
    SCRIPT
  end

  def configure_remote_url(token_value, git_remote, github_web_url, repository)
    uri = URI(github_web_url)
    encoded_token = URI.encode_www_form_component(token_value)
    remote_url = "#{uri.scheme}://x-access-token:#{encoded_token}@#{uri.host}"
    remote_url = "#{remote_url}:#{uri.port}" if uri.port && uri.port != uri.default_port
    remote_url = "#{remote_url}#{uri.path.sub(%r{/+\z}, '')}/#{repository}.git"
    run_git('remote', 'set-url', git_remote, remote_url)
  end

  def run_git(*args)
    return if system('git', *args)

    fail_with("git #{args.join(' ')} failed.")
  end

  def shell_quote(value)
    "'#{value.to_s.gsub("'", "'\\\\''")}'"
  end

  def fail_with(message)
    warn "github-app-token: #{message}"
    exit 1
  end
end

GitHubAppTokenGit.run if __FILE__ == $PROGRAM_NAME
