import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  createToken,
  normalizePrivateKey,
  parsePermissions,
  redact,
} from '../src/scripts/create_token.mjs';

const repoInstallation = JSON.parse(
  fs.readFileSync(new URL('./fixtures/responses/repo-installation.json', import.meta.url), 'utf8'),
);
const accessToken = JSON.parse(
  fs.readFileSync(new URL('./fixtures/responses/access-token.json', import.meta.url), 'utf8'),
);

const { privateKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const privateKeyPem = privateKey.export({ type: 'pkcs1', format: 'pem' });

const tempRuntime = () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'github-app-token-test-'));
  return {
    directory,
    bashEnv: path.join(directory, 'bash_env'),
    outputJson: path.join(directory, 'result.json'),
  };
};

const baseOptions = (overrides = {}) => ({
  appId: '12345',
  appIdEnvVar: 'GITHUB_APP_ID',
  privateKeyEnvVar: 'GITHUB_APP_PRIVATE_KEY',
  privateKeyBase64: false,
  installationId: '123456',
  installationIdEnvVar: 'GITHUB_APP_INSTALLATION_ID',
  owner: 'octo-org',
  repo: 'repo-a',
  installationLookup: 'repo',
  repositories: '',
  repositoryIds: '',
  permissions: '',
  githubApiUrl: 'https://api.github.com',
  githubApiVersion: '2026-03-10',
  tokenEnvVar: 'GH_APP_TOKEN',
  exportEnvPrefix: 'GH_APP',
  outputJson: '/tmp/github-app-token-result.json',
  includeTokenInOutputJson: false,
  ...overrides,
});

const jsonResponse = (body, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  async text() {
    return JSON.stringify(body);
  },
});

const fakeFetch = () => {
  const calls = [];
  return {
    calls,
    fetchImpl: async (url, options) => {
      calls.push({
        url,
        options,
        body: options.body ? JSON.parse(options.body) : undefined,
      });

      if (url.endsWith('/repos/octo-org/repo-a/installation')) {
        return jsonResponse(repoInstallation);
      }
      if (url.endsWith('/access_tokens')) {
        return jsonResponse(accessToken);
      }
      return jsonResponse({ message: 'not found' }, 404);
    },
  };
};

const jwtPayload = (authorizationHeader) => {
  const token = authorizationHeader.replace('Bearer ', '');
  const payload = token.split('.')[1];
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
};

test('normalizes raw, escaped newline, and base64 private keys', () => {
  const expected = privateKeyPem.endsWith('\n') ? privateKeyPem : `${privateKeyPem}\n`;
  assert.equal(normalizePrivateKey(privateKeyPem), expected);
  assert.equal(normalizePrivateKey(privateKeyPem.replace(/\n/g, '\\n')), expected);
  assert.equal(normalizePrivateKey(Buffer.from(privateKeyPem).toString('base64'), { base64: true }), expected);
});

test('uses app_id parameter and skips lookup when installation_id is explicit', async () => {
  const runtime = tempRuntime();
  const { calls, fetchImpl } = fakeFetch();

  await createToken(baseOptions({ outputJson: runtime.outputJson }), {
    env: {
      BASH_ENV: runtime.bashEnv,
      GITHUB_APP_PRIVATE_KEY: privateKeyPem,
    },
    fetchImpl,
    now: new Date('2026-05-08T00:00:00Z'),
  });

  assert.equal(calls.length, 1);
  assert.match(calls[0].url, /\/app\/installations\/123456\/access_tokens$/);
  assert.equal(jwtPayload(calls[0].options.headers.Authorization).iss, '12345');
});

test('uses app_id_env_var when app_id is empty', async () => {
  const runtime = tempRuntime();
  const { calls, fetchImpl } = fakeFetch();

  await createToken(baseOptions({ appId: '', appIdEnvVar: 'APP_ID', outputJson: runtime.outputJson }), {
    env: {
      APP_ID: '67890',
      BASH_ENV: runtime.bashEnv,
      GITHUB_APP_PRIVATE_KEY: privateKeyPem,
    },
    fetchImpl,
    now: new Date('2026-05-08T00:00:00Z'),
  });

  assert.equal(jwtPayload(calls[0].options.headers.Authorization).iss, '67890');
});

test('looks up installation_id from the repository when not explicit', async () => {
  const runtime = tempRuntime();
  const { calls, fetchImpl } = fakeFetch();

  await createToken(baseOptions({ installationId: '', outputJson: runtime.outputJson }), {
    env: {
      BASH_ENV: runtime.bashEnv,
      GITHUB_APP_PRIVATE_KEY: privateKeyPem,
    },
    fetchImpl,
    now: new Date('2026-05-08T00:00:00Z'),
  });

  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /\/repos\/octo-org\/repo-a\/installation$/);
  assert.match(calls[1].url, /\/app\/installations\/123456\/access_tokens$/);
});

test('validates permissions JSON', () => {
  assert.deepEqual(parsePermissions('{"contents":"write"}'), { contents: 'write' });
  assert.throws(() => parsePermissions('[]'), /JSON object/);
  assert.throws(() => parsePermissions('{'), /valid JSON object/);
});

test('rejects repositories and repository_ids together', async () => {
  const runtime = tempRuntime();
  const { fetchImpl } = fakeFetch();

  await assert.rejects(
    createToken(baseOptions({ repositories: 'repo-a', repositoryIds: '1', outputJson: runtime.outputJson }), {
      env: {
        BASH_ENV: runtime.bashEnv,
        GITHUB_APP_PRIVATE_KEY: privateKeyPem,
      },
      fetchImpl,
    }),
    /cannot be used together/,
  );
});

test('omits token from output JSON by default and exports it through BASH_ENV', async () => {
  const runtime = tempRuntime();
  const { fetchImpl } = fakeFetch();

  await createToken(baseOptions({ outputJson: runtime.outputJson }), {
    env: {
      BASH_ENV: runtime.bashEnv,
      GITHUB_APP_PRIVATE_KEY: privateKeyPem,
    },
    fetchImpl,
    now: new Date('2026-05-08T00:00:00Z'),
  });

  const output = JSON.parse(fs.readFileSync(runtime.outputJson, 'utf8'));
  assert.equal(output.token, undefined);
  assert.equal(output.token_exported_to, 'GH_APP_TOKEN');
  assert.equal(output.installation_id, 123456);
  assert.match(fs.readFileSync(runtime.bashEnv, 'utf8'), /export GH_APP_TOKEN='ghs_example_token'/);
});

test('redacts private key and token values from errors', () => {
  const message = redact(`failed with ${privateKeyPem} and ghs_example_token`, [
    privateKeyPem,
    'ghs_example_token',
  ]);

  assert.doesNotMatch(message, /BEGIN RSA PRIVATE KEY/);
  assert.doesNotMatch(message, /ghs_example_token/);
  assert.match(message, /\[REDACTED\]/);
});
