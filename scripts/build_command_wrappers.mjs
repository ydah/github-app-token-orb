#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const scriptsDir = path.join(root, 'src', 'scripts');

const read = (fileName) => fs.readFileSync(path.join(scriptsDir, fileName), 'utf8');
const wrapBase64 = (content) => content.match(/.{1,76}/g).join('\n');
const encode = (fileName) => wrapBase64(Buffer.from(read(fileName), 'utf8').toString('base64'));

const createToken = encode('create_token.mjs');
const configureGit = encode('configure_git.sh');

const createCommand = `#!/usr/bin/env bash
set -euo pipefail

major_version="$(node -p 'process.versions.node.split(".")[0]')"
if [ "\${major_version}" -lt 20 ]; then
  echo "Node.js 20 or newer is required." >&2
  exit 1
fi

write_base64_file() {
  local output_path="$1"
  local content_base64="$2"
  node -e 'const fs = require("node:fs"); fs.writeFileSync(process.argv[1], Buffer.from(process.argv[2].replace(/\\s+/g, ""), "base64").toString("utf8"));' "\${output_path}" "\${content_base64}"
  chmod 700 "\${output_path}"
}

create_token_mjs_base64='
${createToken}
'

create_token_path="\${TMPDIR:-/tmp}/github-app-token-create.mjs"
write_base64_file "\${create_token_path}" "\${create_token_mjs_base64}"
node "\${create_token_path}"

if [ "\${GITHUB_APP_TOKEN_SHOULD_CONFIGURE_GIT:-false}" = "true" ]; then
  if [ -n "\${BASH_ENV:-}" ] && [ -f "\${BASH_ENV}" ]; then
    . "\${BASH_ENV}"
  fi

  configure_git_sh_base64='
${configureGit}
'

  configure_git_path="\${TMPDIR:-/tmp}/github-app-token-configure-git.sh"
  write_base64_file "\${configure_git_path}" "\${configure_git_sh_base64}"
  "\${configure_git_path}"
fi
`;

fs.writeFileSync(path.join(scriptsDir, 'create_command.sh'), createCommand);
