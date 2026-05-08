#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const RUNTIME_PREFIX = 'GITHUB_APP_TOKEN_';
const ENV_NAME_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
const INSTALLATION_LOOKUPS = new Set(['repo', 'org', 'user', 'app-list', 'none']);

export class InputError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InputError';
  }
}

export class GitHubApiError extends Error {
  constructor(message) {
    super(message);
    this.name = 'GitHubApiError';
  }
}

export const parseBoolean = (value, defaultValue = false) => {
  if (value === undefined || value === null || value === '') {
    return defaultValue;
  }

  if (typeof value === 'boolean') {
    return value;
  }

  const normalized = String(value).trim().toLowerCase();
  if (['true', '1', 'yes', 'y'].includes(normalized)) {
    return true;
  }
  if (['false', '0', 'no', 'n'].includes(normalized)) {
    return false;
  }

  throw new InputError(`Invalid boolean value: ${value}`);
};

export const expandEnvReference = (value, env = process.env) => {
  if (typeof value !== 'string') {
    return value;
  }

  const trimmed = value.trim();
  const braced = trimmed.match(/^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$/);
  if (braced) {
    return env[braced[1]] ?? '';
  }

  const plain = trimmed.match(/^\$([A-Za-z_][A-Za-z0-9_]*)$/);
  if (plain) {
    return env[plain[1]] ?? '';
  }

  return value;
};

const runtimeValue = (env, name, fallback = '') =>
  expandEnvReference(env[`${RUNTIME_PREFIX}${name}`] ?? fallback, env);

export const readRuntimeOptions = (env = process.env) => ({
  appId: runtimeValue(env, 'APP_ID'),
  appIdEnvVar: runtimeValue(env, 'APP_ID_ENV_VAR', 'GITHUB_APP_ID'),
  privateKeyEnvVar: runtimeValue(env, 'PRIVATE_KEY_ENV_VAR', 'GITHUB_APP_PRIVATE_KEY'),
  privateKeyBase64: parseBoolean(runtimeValue(env, 'PRIVATE_KEY_BASE64', 'false')),
  installationId: runtimeValue(env, 'INSTALLATION_ID'),
  installationIdEnvVar: runtimeValue(env, 'INSTALLATION_ID_ENV_VAR', 'GITHUB_APP_INSTALLATION_ID'),
  owner: runtimeValue(env, 'OWNER', '${CIRCLE_PROJECT_USERNAME}'),
  repo: runtimeValue(env, 'REPO', '${CIRCLE_PROJECT_REPONAME}'),
  installationLookup: runtimeValue(env, 'INSTALLATION_LOOKUP', 'repo'),
  repositories: runtimeValue(env, 'REPOSITORIES'),
  repositoryIds: runtimeValue(env, 'REPOSITORY_IDS'),
  permissions: runtimeValue(env, 'PERMISSIONS'),
  githubApiUrl: runtimeValue(env, 'GITHUB_API_URL', 'https://api.github.com'),
  githubApiVersion: runtimeValue(env, 'GITHUB_API_VERSION', '2026-03-10'),
  tokenEnvVar: runtimeValue(env, 'TOKEN_ENV_VAR', 'GH_APP_TOKEN'),
  exportEnvPrefix: runtimeValue(env, 'EXPORT_ENV_PREFIX', 'GH_APP'),
  outputJson: runtimeValue(env, 'OUTPUT_JSON', '/tmp/github-app-token-result.json'),
  includeTokenInOutputJson: parseBoolean(runtimeValue(env, 'INCLUDE_TOKEN_IN_OUTPUT_JSON', 'false')),
});

export const normalizePrivateKey = (rawValue, { base64 = false } = {}) => {
  if (!rawValue || !String(rawValue).trim()) {
    throw new InputError('GitHub App private key is empty.');
  }

  let privateKey = String(rawValue).trim();
  if (base64) {
    privateKey = Buffer.from(privateKey.replace(/\s+/g, ''), 'base64').toString('utf8').trim();
  }

  privateKey = privateKey.replace(/\\n/g, '\n').trim();
  const hasHeader = /-----BEGIN (?:RSA )?PRIVATE KEY-----/.test(privateKey);
  const hasFooter = /-----END (?:RSA )?PRIVATE KEY-----/.test(privateKey);
  if (!hasHeader || !hasFooter) {
    throw new InputError('GitHub App private key must be a PEM private key.');
  }

  return privateKey.endsWith('\n') ? privateKey : `${privateKey}\n`;
};

const validateEnvName = (value, label) => {
  if (!ENV_NAME_PATTERN.test(value)) {
    throw new InputError(`${label} must be a valid environment variable name.`);
  }
};

const clean = (value) => String(value ?? '').trim();

export const parseCommaList = (value) =>
  clean(value)
    ? clean(value)
        .split(',')
        .map((item) => item.trim())
        .filter(Boolean)
    : [];

export const parseRepositoryIds = (value) =>
  parseCommaList(value).map((item) => {
    if (!/^\d+$/.test(item)) {
      throw new InputError('repository_ids must contain only numeric IDs.');
    }
    return Number(item);
  });

export const parsePermissions = (value) => {
  if (!clean(value)) {
    return undefined;
  }

  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw new InputError(`permissions must be a valid JSON object: ${error.message}`);
  }

  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new InputError('permissions must be a JSON object.');
  }

  return parsed;
};

export const createAppJwt = ({ appId, privateKey, now = new Date() }) => {
  const nowSeconds = Math.floor(now.getTime() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(
    JSON.stringify({
      iat: nowSeconds - 60,
      exp: nowSeconds + 540,
      iss: appId,
    }),
  ).toString('base64url');
  const body = `${header}.${payload}`;
  const signer = crypto.createSign('RSA-SHA256');
  signer.update(body);
  signer.end();
  const signature = signer.sign(crypto.createPrivateKey(privateKey)).toString('base64url');
  return `${body}.${signature}`;
};

const apiUrlWithPath = (apiUrl, requestPath) =>
  `${apiUrl.replace(/\/+$/, '')}${requestPath.startsWith('/') ? requestPath : `/${requestPath}`}`;

export const requestGitHub = async ({
  apiUrl,
  apiVersion,
  method,
  requestPath,
  authToken,
  body,
  fetchImpl = globalThis.fetch,
}) => {
  const response = await fetchImpl(apiUrlWithPath(apiUrl, requestPath), {
    method,
    headers: {
      Accept: 'application/vnd.github+json',
      Authorization: `Bearer ${authToken}`,
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': apiVersion,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : {};
  if (!response.ok) {
    const detail = data.message ? `: ${data.message}` : '';
    throw new GitHubApiError(`GitHub API ${method} ${requestPath} failed with ${response.status}${detail}`);
  }

  return data;
};

const encodePathPart = (value) => encodeURIComponent(value).replace(/%2F/g, '/');

export const lookupInstallationId = async ({ options, jwt, fetchImpl }) => {
  const owner = clean(options.owner);
  const repo = clean(options.repo);

  if (options.installationLookup === 'repo') {
    if (!owner || !repo) {
      throw new InputError('owner and repo are required for repo installation lookup.');
    }
    const data = await requestGitHub({
      apiUrl: options.githubApiUrl,
      apiVersion: options.githubApiVersion,
      method: 'GET',
      requestPath: `/repos/${encodePathPart(owner)}/${encodePathPart(repo)}/installation`,
      authToken: jwt,
      fetchImpl,
    });
    return clean(data.id);
  }

  if (options.installationLookup === 'org' || options.installationLookup === 'user') {
    if (!owner) {
      throw new InputError(`owner is required for ${options.installationLookup} installation lookup.`);
    }
    const segment = options.installationLookup === 'org' ? 'orgs' : 'users';
    const data = await requestGitHub({
      apiUrl: options.githubApiUrl,
      apiVersion: options.githubApiVersion,
      method: 'GET',
      requestPath: `/${segment}/${encodePathPart(owner)}/installation`,
      authToken: jwt,
      fetchImpl,
    });
    return clean(data.id);
  }

  if (options.installationLookup === 'app-list') {
    if (!owner) {
      throw new InputError('owner is required for app-list installation lookup.');
    }
    const data = await requestGitHub({
      apiUrl: options.githubApiUrl,
      apiVersion: options.githubApiVersion,
      method: 'GET',
      requestPath: '/app/installations',
      authToken: jwt,
      fetchImpl,
    });
    const installations = Array.isArray(data) ? data : data.installations ?? [];
    const match = installations.find((installation) => {
      const login = installation?.account?.login ?? '';
      return login.toLowerCase() === owner.toLowerCase();
    });
    if (!match) {
      throw new InputError(`No GitHub App installation found for ${owner}.`);
    }
    return clean(match.id);
  }

  throw new InputError('installation_id is required when installation_lookup is none.');
};

export const buildAccessTokenBody = ({ repositories, repositoryIds, permissions }) => {
  const body = {};
  if (repositories.length > 0) {
    body.repositories = repositories;
  }
  if (repositoryIds.length > 0) {
    body.repository_ids = repositoryIds;
  }
  if (permissions) {
    body.permissions = permissions;
  }
  return Object.keys(body).length > 0 ? body : undefined;
};

const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

const writeBashEnv = ({ bashEnvPath, tokenEnvVar, exportEnvPrefix, outputJson, result }) => {
  if (!bashEnvPath) {
    throw new InputError('BASH_ENV is not set; CircleCI needs it to export values for later steps.');
  }

  fs.mkdirSync(path.dirname(bashEnvPath), { recursive: true });
  const lines = [
    `export ${tokenEnvVar}=${shellQuote(result.token)}`,
    `export ${exportEnvPrefix}_INSTALLATION_ID=${shellQuote(result.installationId)}`,
    `export ${exportEnvPrefix}_EXPIRES_AT=${shellQuote(result.expiresAt)}`,
    `export ${exportEnvPrefix}_OUTPUT_JSON=${shellQuote(outputJson)}`,
  ];
  fs.appendFileSync(bashEnvPath, `${lines.join('\n')}\n`, { mode: 0o600 });
};

const writeOutputJson = ({ outputJson, metadata }) => {
  fs.mkdirSync(path.dirname(outputJson), { recursive: true });
  fs.writeFileSync(outputJson, `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o600 });
  fs.chmodSync(outputJson, 0o600);
};

export const redact = (text, secrets) => {
  let redacted = String(text);
  const uniqueSecrets = [...new Set(secrets.filter((secret) => typeof secret === 'string' && secret.length >= 4))];
  for (const secret of uniqueSecrets.sort((a, b) => b.length - a.length)) {
    redacted = redacted.split(secret).join('[REDACTED]');
  }
  return redacted;
};

const validateOptions = (options) => {
  validateEnvName(options.appIdEnvVar, 'app_id_env_var');
  validateEnvName(options.privateKeyEnvVar, 'private_key_env_var');
  validateEnvName(options.installationIdEnvVar, 'installation_id_env_var');
  validateEnvName(options.tokenEnvVar, 'token_env_var');
  validateEnvName(options.exportEnvPrefix, 'export_env_prefix');

  if (!INSTALLATION_LOOKUPS.has(options.installationLookup)) {
    throw new InputError('installation_lookup must be repo, org, user, app-list, or none.');
  }
};

export const createToken = async (options, { env = process.env, fetchImpl = globalThis.fetch, now = new Date() } = {}) => {
  validateOptions(options);

  const appId = clean(options.appId) || clean(env[options.appIdEnvVar]);
  if (!appId) {
    throw new InputError('GitHub App ID is required through app_id or app_id_env_var.');
  }

  const privateKey = normalizePrivateKey(env[options.privateKeyEnvVar], { base64: options.privateKeyBase64 });
  const explicitInstallationId = clean(options.installationId) || clean(env[options.installationIdEnvVar]);
  const repositories = parseCommaList(options.repositories);
  const repositoryIds = parseRepositoryIds(options.repositoryIds);
  const permissions = parsePermissions(options.permissions);

  if (repositories.length > 0 && repositoryIds.length > 0) {
    throw new InputError('repositories and repository_ids cannot be used together.');
  }

  const jwt = createAppJwt({ appId, privateKey, now });
  const installationId =
    explicitInstallationId || (await lookupInstallationId({ options, jwt, fetchImpl }));

  const tokenResponse = await requestGitHub({
    apiUrl: options.githubApiUrl,
    apiVersion: options.githubApiVersion,
    method: 'POST',
    requestPath: `/app/installations/${encodePathPart(installationId)}/access_tokens`,
    authToken: jwt,
    body: buildAccessTokenBody({ repositories, repositoryIds, permissions }),
    fetchImpl,
  });

  if (!tokenResponse.token) {
    throw new GitHubApiError('GitHub access token response did not include a token.');
  }

  const repositoryNames = Array.isArray(tokenResponse.repositories)
    ? tokenResponse.repositories.map((repository) => repository.name).filter(Boolean)
    : repositories;

  const metadata = {
    installation_id: Number.isNaN(Number(installationId)) ? installationId : Number(installationId),
    expires_at: tokenResponse.expires_at,
    repository_selection: tokenResponse.repository_selection,
    permissions: tokenResponse.permissions ?? {},
    repositories: repositoryNames,
    token_exported_to: options.tokenEnvVar,
  };

  if (options.includeTokenInOutputJson) {
    metadata.token = tokenResponse.token;
  }

  writeOutputJson({ outputJson: options.outputJson, metadata });
  writeBashEnv({
    bashEnvPath: env.BASH_ENV,
    tokenEnvVar: options.tokenEnvVar,
    exportEnvPrefix: options.exportEnvPrefix,
    outputJson: options.outputJson,
    result: {
      token: tokenResponse.token,
      installationId,
      expiresAt: tokenResponse.expires_at,
    },
  });

  return metadata;
};

const main = async () => {
  let options;
  try {
    options = readRuntimeOptions(process.env);
    const metadata = await createToken(options);
    console.log(
      `GitHub App installation token exported to ${metadata.token_exported_to}; metadata written to ${options.outputJson}.`,
    );
  } catch (error) {
    const privateKey = options?.privateKeyEnvVar ? process.env[options.privateKeyEnvVar] : undefined;
    const message = error?.stack || error?.message || String(error);
    console.error(redact(message, [privateKey]));
    process.exitCode = 1;
  }
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
