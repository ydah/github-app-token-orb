#!/usr/bin/env bash
set -euo pipefail

if [ -n "${BASH_ENV:-}" ] && [ -f "${BASH_ENV}" ]; then
  # shellcheck source=/dev/null
  . "${BASH_ENV}"
fi

env_name_pattern='^[A-Za-z_][A-Za-z0-9_]*$'

fail() {
  echo "github-app-token: $1" >&2
  exit 1
}

expand_env_ref() {
  local value="$1"
  local output="$value"
  local var_name=""

  while [[ "${output}" =~ ^(.*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]]; do
    var_name="${BASH_REMATCH[2]}"
    output="${BASH_REMATCH[1]}${!var_name:-}${BASH_REMATCH[3]}"
  done

  if [[ "${output}" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)$ ]]; then
    var_name="${BASH_REMATCH[1]}"
    printf '%s' "${!var_name:-}"
    return
  fi

  printf '%s' "${output}"
}

token_env_var="$(expand_env_ref "${GITHUB_APP_TOKEN_CONFIGURE_TOKEN_ENV_VAR:-GH_APP_TOKEN}")"
repository="$(expand_env_ref "${GITHUB_APP_TOKEN_CONFIGURE_REPOSITORY:-${CIRCLE_PROJECT_USERNAME:-}/${CIRCLE_PROJECT_REPONAME:-}}")"
git_remote="$(expand_env_ref "${GITHUB_APP_TOKEN_CONFIGURE_GIT_REMOTE:-origin}")"
github_web_url="$(expand_env_ref "${GITHUB_APP_TOKEN_CONFIGURE_GITHUB_WEB_URL:-https://github.com}")"
method="$(expand_env_ref "${GITHUB_APP_TOKEN_CONFIGURE_METHOD:-askpass}")"

[[ "${token_env_var}" =~ ${env_name_pattern} ]] || fail "token_env_var must be a valid environment variable name."
token_value="${!token_env_var:-}"
[ -n "${token_value}" ] || fail "Token environment variable ${token_env_var} is empty."
[[ "${repository}" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || fail "repository must use owner/repo format."
[ -n "${git_remote}" ] || fail "git_remote must not be empty."

github_web_url="${github_web_url%/}"
repository_url="${github_web_url}/${repository}.git"

case "${method}" in
  askpass)
    askpass_file="${TMPDIR:-/tmp}/github-app-token-askpass-${token_env_var}.sh"
    {
      printf '%s\n' '#!/usr/bin/env sh'
      printf '%s\n' 'case "$1" in'
      printf '%s\n' '  *Username*) printf "%s\n" "x-access-token" ;;'
      printf '%s\n' '  *Password*) printenv "${GITHUB_APP_TOKEN_ASKPASS_ENV_VAR}" ;;'
      printf '%s\n' '  *) printf "\n" ;;'
      printf '%s\n' 'esac'
    } > "${askpass_file}"
    chmod 700 "${askpass_file}"
    git remote set-url "${git_remote}" "${repository_url}"
    git config --local core.askPass "${askpass_file}"
    git config --local credential.username "x-access-token"

    if [ -n "${BASH_ENV:-}" ]; then
      {
        printf "export GIT_ASKPASS='%s'\n" "${askpass_file}"
        printf "export GITHUB_APP_TOKEN_ASKPASS_ENV_VAR='%s'\n" "${token_env_var}"
      } >> "${BASH_ENV}"
    fi
    ;;
  remote-url)
    encoded_token="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "${token_value}")"
    protocol="${github_web_url%%://*}"
    host_and_path="${github_web_url#*://}"
    git remote set-url "${git_remote}" "${protocol}://x-access-token:${encoded_token}@${host_and_path}/${repository}.git"
    ;;
  *)
    fail "method must be askpass or remote-url."
    ;;
esac

echo "Git authentication configured for ${repository} using ${method}."
