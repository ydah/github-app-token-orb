# GitHub App Token Orb

Generate short-lived GitHub App installation access tokens inside CircleCI jobs.

This orb provides a CircleCI experience similar to `actions/create-github-app-token` for GitHub Actions. It creates an App JWT from your GitHub App ID and private key, resolves the installation ID when needed, creates an installation access token, exports the token through `$BASH_ENV`, and writes non-secret metadata to JSON.

## Usage

```yaml
version: 2.1

orbs:
  app-token: ydah/github-app-token@x.y.z

jobs:
  use-app-token:
    docker:
      - image: cimg/node:lts
    steps:
      - checkout
      - app-token/create:
          app_id_env_var: GITHUB_APP_ID
          private_key_env_var: GITHUB_APP_PRIVATE_KEY
          installation_lookup: repo
          token_env_var: GH_APP_TOKEN
      - run:
          name: Call GitHub API
          command: |
            curl -sSfL \
              -H "Accept: application/vnd.github+json" \
              -H "Authorization: Bearer ${GH_APP_TOKEN}" \
              -H "X-GitHub-Api-Version: 2026-03-10" \
              "https://api.github.com/repos/${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"

workflows:
  use-app-token:
    jobs:
      - use-app-token
```

## GitHub App Setup

Create or choose a GitHub App, note its App ID, generate a private key, install the App on the target repository or organization, and grant the minimum repository permissions your job needs.

Store these values in a CircleCI Context or project environment variables:

- `GITHUB_APP_ID`
- `GITHUB_APP_PRIVATE_KEY`
- `GITHUB_APP_INSTALLATION_ID` when you do not want lookup API calls

Installation access tokens expire after about one hour. Generate a token inside each job that needs it.

## Private Key Formats

The private key must be passed by environment variable name, not as a literal orb parameter.

Raw PEM:

```text
-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----
```

Escaped newlines:

```text
-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----
```

Base64 encoded PEM:

```yaml
- app-token/create:
    private_key_base64: true
```

## Security

Do not echo the generated token. CircleCI does not provide the same dynamic masking behavior as GitHub Actions `add-mask`, so this orb never prints the token.

By default, `output_json` does not include the token. Avoid `include_token_in_output_json: true`; use it only when a downstream tool cannot read environment variables and protect the file as a secret.

The recommended Git authentication method is `askpass`, which avoids storing the token in the Git remote URL. The `remote-url` method embeds the token in `.git/config` and should only be used for short-lived, isolated jobs.

## Commands

### `create`

Generates an installation access token and exports it for later steps.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `app_id` | string | `""` | GitHub App ID. When empty, the value is read from `app_id_env_var`. |
| `app_id_env_var` | string | `GITHUB_APP_ID` | Environment variable name that stores the GitHub App ID. |
| `private_key_env_var` | string | `GITHUB_APP_PRIVATE_KEY` | Environment variable name that stores the private key. |
| `private_key_base64` | boolean | `false` | Decode the private key from base64 before use. |
| `installation_id` | string | `""` | Installation ID. When empty, the ID is read from `installation_id_env_var` or inferred. |
| `installation_id_env_var` | string | `GITHUB_APP_INSTALLATION_ID` | Environment variable name that stores the installation ID. |
| `owner` | string | `${CIRCLE_PROJECT_USERNAME}` | Owner used for installation lookup. |
| `repo` | string | `${CIRCLE_PROJECT_REPONAME}` | Repository used for installation lookup. |
| `installation_lookup` | enum | `repo` | `repo`, `org`, `user`, `app-list`, or `none`. |
| `repositories` | string | `""` | Comma-separated repository names used to restrict the token. |
| `repository_ids` | string | `""` | Comma-separated repository IDs used to restrict the token. |
| `permissions` | string | `""` | JSON object used to restrict token permissions. |
| `github_api_url` | string | `https://api.github.com` | GitHub REST API base URL. |
| `github_api_version` | string | `2026-03-10` | `X-GitHub-Api-Version` header value. |
| `token_env_var` | string | `GH_APP_TOKEN` | Environment variable name used to export the token. |
| `export_env_prefix` | string | `GH_APP` | Prefix used for metadata environment variables. |
| `output_json` | string | `/tmp/github-app-token-result.json` | Path for token metadata JSON. |
| `include_token_in_output_json` | boolean | `false` | Include the token in the JSON output. |
| `configure_git` | boolean | `false` | Configure the current Git remote with the generated token. |
| `git_remote` | string | `origin` | Git remote configured when `configure_git` is true. |

The command appends these variables to `$BASH_ENV` by default:

```bash
GH_APP_TOKEN=<generated token>
GH_APP_INSTALLATION_ID=123456
GH_APP_EXPIRES_AT=2026-05-08T12:34:56Z
GH_APP_OUTPUT_JSON=/tmp/github-app-token-result.json
```

`output_json` contains metadata without the token unless `include_token_in_output_json` is true.

### `configure-git`

Configures the current repository to use an already exported token.

| Parameter | Type | Default | Description |
| --- | --- | --- | --- |
| `token_env_var` | string | `GH_APP_TOKEN` | Environment variable name that stores the token. |
| `repository` | string | `${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}` | Repository in `owner/repo` form. |
| `git_remote` | string | `origin` | Git remote name to configure. |
| `github_web_url` | string | `https://github.com` | GitHub web URL or GitHub Enterprise Server web URL. |
| `method` | enum | `askpass` | `askpass` or `remote-url`. |

## Job

### `create`

Runs the `create` command in the default Node executor. It accepts all `create` command parameters plus `checkout`, which defaults to `false`.

## Installation Lookup

When `installation_id` or `installation_id_env_var` is set, lookup is skipped.

- `repo`: `GET /repos/{owner}/{repo}/installation`
- `org`: `GET /orgs/{owner}/installation`
- `user`: `GET /users/{owner}/installation`
- `app-list`: `GET /app/installations` and match by account login
- `none`: do not infer the installation ID

## Restricted Permissions

```yaml
- app-token/create:
    permissions: '{"contents":"write","pull_requests":"write"}'
    repositories: "${CIRCLE_PROJECT_REPONAME}"
```

`repositories` and `repository_ids` cannot be used together.

## GitHub Enterprise Server

Set `github_api_url` to the API URL and `github_web_url` on `configure-git` when using GitHub Enterprise Server.

```yaml
- app-token/create:
    github_api_url: https://github.example.com/api/v3
- app-token/configure-git:
    github_web_url: https://github.example.com
```

## Development

```bash
npm test
npm run lint
npm run pack
circleci orb validate orb.yml
circleci config validate .circleci/config.yml
```
