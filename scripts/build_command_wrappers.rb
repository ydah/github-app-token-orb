#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
ROOT = Dir.pwd
SCRIPTS_DIR = File.join(ROOT, 'src', 'scripts')

def read_script(file_name)
  File.read(File.join(SCRIPTS_DIR, file_name))
end

def encode_script(file_name)
  Base64.strict_encode64(read_script(file_name)).scan(/.{1,76}/).join("\n")
end

def ruby_runtime_check
  <<~'SH'
    ruby -e 'required = Gem::Version.new("3.1.0"); current = Gem::Version.new(RUBY_VERSION); abort("Ruby 3.1 or newer is required.") if current < required'
  SH
end

def write_base64_function
  <<~'SH'
    write_base64_file() {
      local output_path="$1"
      local content_base64="$2"
      ruby -rbase64 -e 'File.binwrite(ARGV[0], Base64.decode64(ARGV[1].gsub(/\s+/, ""))); File.chmod(0o700, ARGV[0])' "${output_path}" "${content_base64}"
    }
  SH
end

create_token = encode_script('create_token.rb')
configure_git = encode_script('configure_git.rb')

create_command = <<~SH
  #!/usr/bin/env bash
  set -euo pipefail

  #{ruby_runtime_check.chomp}

  #{write_base64_function.chomp}

  create_token_rb_base64='
  #{create_token}
  '

  create_token_path="${TMPDIR:-/tmp}/github-app-token-create.rb"
  write_base64_file "${create_token_path}" "${create_token_rb_base64}"
  ruby "${create_token_path}"

  if [ "${GITHUB_APP_TOKEN_SHOULD_CONFIGURE_GIT:-false}" = "true" ]; then
    if [ -n "${BASH_ENV:-}" ] && [ -f "${BASH_ENV}" ]; then
      . "${BASH_ENV}"
    fi

    configure_git_rb_base64='
  #{configure_git}
    '

    configure_git_path="${TMPDIR:-/tmp}/github-app-token-configure-git.rb"
    write_base64_file "${configure_git_path}" "${configure_git_rb_base64}"
    ruby "${configure_git_path}"
  fi
SH

configure_git_command = <<~SH
  #!/usr/bin/env bash
  set -euo pipefail

  #{ruby_runtime_check.chomp}

  if [ -n "${BASH_ENV:-}" ] && [ -f "${BASH_ENV}" ]; then
    . "${BASH_ENV}"
  fi

  #{write_base64_function.chomp}

  configure_git_rb_base64='
  #{configure_git}
  '

  configure_git_path="${TMPDIR:-/tmp}/github-app-token-configure-git.rb"
  write_base64_file "${configure_git_path}" "${configure_git_rb_base64}"
  ruby "${configure_git_path}"
SH

File.write(File.join(SCRIPTS_DIR, 'create_command.sh'), create_command)
File.write(File.join(SCRIPTS_DIR, 'configure_git_command.sh'), configure_git_command)
