import assert from 'node:assert/strict';
import { execFile as execFileCallback } from 'node:child_process';
import { chmod, copyFile, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import {
  ReleaseCheckError,
  assertStagingTag,
  buildNativeManifest,
  createNativeBuildId,
  postWebhook,
  reserveArtifactDirectory,
  webImageTags,
  writeNativeManifest,
} from './release-artifact-check.mjs';

const execFile = promisify(execFileCallback);
const repositoryRoot = fileURLToPath(new URL('../', import.meta.url));

test('a non-2xx webhook response fails the publication decision', async () => {
  await assert.rejects(
    postWebhook('https://deploy.invalid/hook', {
      fetchImpl: async () => new Response('deployment refused', { status: 503 }),
    }),
    /^ReleaseCheckError: Webhook returned HTTP 503$/,
  );
});

test('a webhook network error fails the publication decision', async () => {
  await assert.rejects(
    postWebhook('https://deploy.invalid/hook', {
      fetchImpl: async () => {
        throw new Error('simulated connection reset');
      },
    }),
    /^ReleaseCheckError: Webhook network error$/,
  );
});

test('a 2xx webhook response succeeds', async () => {
  const result = await postWebhook('https://deploy.invalid/hook', {
    fetchImpl: async () => new Response(null, { status: 204 }),
  });
  assert.equal(result.status, 204);
});

test('staging publication never emits latest', () => {
  assert.deepEqual(
    webImageTags({
      imageName: 'ghcr.io/example/aidhabitat-web',
      imageTag: 'staging',
      sha: '10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    }),
    [
      'ghcr.io/example/aidhabitat-web:staging',
      'ghcr.io/example/aidhabitat-web:staging-10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    ],
  );
});

test('latest remains available only as an explicit manual image tag', () => {
  assert.deepEqual(
    webImageTags({
      imageName: 'ghcr.io/example/aidhabitat-web',
      imageTag: 'latest',
      sha: '10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    }),
    [
      'ghcr.io/example/aidhabitat-web:latest',
      'ghcr.io/example/aidhabitat-web:10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    ],
  );
  assert.throws(() => assertStagingTag('latest'), /requires image_tag=staging/);
});

test('symbol directories are reserved once and never overwritten', async (t) => {
  const fixtureRoot = await mkdtemp(join(tmpdir(), 'aidhabitat-release-'));
  t.after(() => rm(fixtureRoot, { recursive: true, force: true }));
  const symbols = join(fixtureRoot, 'ios', 'build-18', 'symbols');
  await reserveArtifactDirectory(symbols);
  await assert.rejects(
    reserveArtifactDirectory(symbols),
    (error) => error instanceof ReleaseCheckError && /refusing to overwrite/.test(error.message),
  );
});

test('CLI invoked through a symlink executes its checks', async (t) => {
  const fixtureRoot = await mkdtemp(join(tmpdir(), 'aidhabitat-release-link-'));
  t.after(() => rm(fixtureRoot, { recursive: true, force: true }));
  const link = join(fixtureRoot, 'release-check.mjs');
  const artifact = join(fixtureRoot, 'artifact');
  await symlink(join(repositoryRoot, 'tools/release-artifact-check.mjs'), link);
  await execFile(process.execPath, [link, 'reserve-directory', artifact]);
  assert.equal((await stat(artifact)).isDirectory(), true);
  await assert.rejects(execFile(process.execPath, [link, 'reserve-directory', artifact]),
    (error) => error.code === 1 && /refusing to overwrite/.test(error.stderr));
});

test('native manifests trace the local build without storing secrets', async (t) => {
  const fixtureRoot = await mkdtemp(join(tmpdir(), 'aidhabitat-manifest-'));
  t.after(() => rm(fixtureRoot, { recursive: true, force: true }));
  const output = join(fixtureRoot, 'manifest.json');
  const buildId = createNativeBuildId({
    version: '1.0.0',
    buildNumber: '18',
    sha: '10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    dirty: true,
    timestamp: new Date('2026-09-09T10:00:00.000Z'),
    nonce: 42,
  });
  const input = {
    buildId,
    createdAt: '2026-09-09T10:00:00.000Z',
    gitSha: '10df5d4c289ffe757af6027f0be0f670fa8f97b7',
    dirty: true,
    dirtyAccepted: true,
    version: '1.0.0',
    buildNumber: '18',
    flutterSdk: '3.38.4',
    dartSdk: '3.10.3',
    platformSdk: 'Xcode 26.6',
    platform: 'ios',
    platformApi: 'iOS 26.5',
    backendApi: 'https://api.aidhabitat.fr/v1?temporary_token=secret',
    symbolsDirectory: 'build/native-releases/ios/example/symbols',
    bootstrapPassword: 'must-never-be-serialized',
  };

  const manifest = buildNativeManifest(input);
  assert.equal(manifest.target.backendApi, 'https://api.aidhabitat.fr/v1');
  assert.equal(manifest.checks.remoteBuildNumberVerified, false);
  assert.match(manifest.remainingRemoteVerification, /App Store Connect/);

  await writeNativeManifest(output, input);
  const serialized = await readFile(output, 'utf8');
  assert.doesNotMatch(serialized, /temporary_token|must-never-be-serialized|secret/);
  assert.match(serialized, /"dirtyReleaseExplicitlyAccepted": true/);
});

test('the native release command requires dirty acceptance and preserves prior symbols', async (t) => {
  const fixtureRoot = await mkdtemp(join(tmpdir(), 'aidhabitat-native-command-'));
  t.after(() => rm(fixtureRoot, { recursive: true, force: true }));
  const fakeBin = join(fixtureRoot, 'bin');
  const releaseRoot = join(fixtureRoot, 'releases');
  await reserveArtifactDirectory(fakeBin);
  const appRoot = join(fixtureRoot, 'aid_habitat_app');
  await mkdir(join(appRoot, 'tool'), { recursive: true });
  await mkdir(join(appRoot, 'macos'), { recursive: true });
  await mkdir(join(fixtureRoot, 'tools'), { recursive: true });
  await writeFile(join(appRoot, 'pubspec.yaml'), 'name: fixture\nversion: 1.0.0+18\n');
  await writeFile(join(appRoot, 'macos/Podfile'), "platform :osx, '13.0'\n");
  const script = join(appRoot, 'tool/build_native_release.sh');
  await copyFile(join(repositoryRoot, 'aid_habitat_app/tool/build_native_release.sh'), script);
  await chmod(script, 0o755);
  await copyFile(join(repositoryRoot, 'tools/release-artifact-check.mjs'),
    join(fixtureRoot, 'tools/release-artifact-check.mjs'));

  const fakeGit = join(fakeBin, 'git');
  await writeFile(fakeGit, `#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  rev-parse) printf '%s\\n' '10df5d4c289ffe757af6027f0be0f670fa8f97b7' ;;
  status) if [ "\${FIXTURE_DIRTY:-1}" = 1 ]; then printf ' M fixture.txt\\n'; fi ;;
  *) exit 99 ;;
esac
`);
  await chmod(fakeGit, 0o755);

  const fakeFlutter = join(fakeBin, 'flutter');
  await writeFile(
    fakeFlutter,
    `#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "--version" ]; then
  printf '%s\\n' '{"frameworkVersion":"3.38.4-fixture","dartSdkVersion":"3.10.3-fixture"}'
  exit 0
fi
if [ "\${1:-}" = "build" ]; then
  if [ "\${FIXTURE_BUILD_FAIL:-0}" = 1 ]; then exit 7; fi
  for argument in "$@"; do
    case "$argument" in
      --split-debug-info=*)
        symbols="\${argument#*=}"
        printf 'fixture symbols\\n' > "$symbols/app.fixture.symbols"
        ;;
    esac
  done
fi
`,
  );
  await chmod(fakeFlutter, 0o755);

  const fakeXcodebuild = join(fakeBin, 'xcodebuild');
  await writeFile(
    fakeXcodebuild,
    "#!/usr/bin/env bash\nprintf 'Xcode fixture\\nBuild version fixture\\n'\n",
  );
  await chmod(fakeXcodebuild, 0o755);

  const environment = {
    ...process.env,
    PATH: `${fakeBin}:${process.env.PATH}`,
    FLUTTER_BIN: fakeFlutter,
    AIDHABITAT_API_BASE_URL: 'https://api.fixture.invalid',
    AIDHABITAT_RELEASE_ROOT: releaseRoot,
    AIDHABITAT_BUILD_ID: 'fixture-build-18',
    AIDHABITAT_ALLOW_DIRTY_RELEASE: '0',
    AIDHABITAT_DEBUG_INFO: '',
    AIDHABITAT_BOOTSTRAP_PASSWORD: '',
    FIXTURE_DIRTY: '1',
    FIXTURE_BUILD_FAIL: '0',
  };

  await assert.rejects(
    execFile(script, ['macos'], { cwd: appRoot, env: environment }),
    (error) => /Arbre Git modifié/.test(error.stderr),
  );

  await execFile(script, ['macos', '--allow-dirty'], {
    cwd: appRoot,
    env: environment,
  });
  const buildDirectory = join(releaseRoot, 'macos', 'fixture-build-18');
  const manifest = JSON.parse(await readFile(join(buildDirectory, 'manifest.json'), 'utf8'));
  const symbolsBefore = await readFile(
    join(buildDirectory, 'symbols', 'app.fixture.symbols'),
    'utf8',
  );
  assert.equal(manifest.status, 'completed');
  assert.equal(manifest.source.dirty, true);
  assert.equal(manifest.source.dirtyReleaseExplicitlyAccepted, true);

  await assert.rejects(
    execFile(script, ['macos', '--allow-dirty'], {
      cwd: appRoot,
      env: environment,
    }),
    (error) => /refusing to overwrite/.test(error.stderr),
  );
  assert.equal(
    await readFile(join(buildDirectory, 'symbols', 'app.fixture.symbols'), 'utf8'),
    symbolsBefore,
  );

  await execFile(script, ['macos'], { cwd: appRoot, env: {
    ...environment, FIXTURE_DIRTY: '0', AIDHABITAT_BUILD_ID: 'clean-build',
  } });
  const clean = JSON.parse(await readFile(join(releaseRoot, 'macos/clean-build/manifest.json')));
  assert.equal(clean.status, 'completed');
  assert.equal(clean.source.dirty, false);
  await assert.rejects(execFile(script, ['macos', '--allow-dirty'], {
    cwd: appRoot, env: {
      ...environment, FIXTURE_BUILD_FAIL: '1', AIDHABITAT_BUILD_ID: 'failed-build',
    },
  }), (error) => error.code === 7);
  const failed = JSON.parse(await readFile(join(releaseRoot, 'macos/failed-build/manifest.json')));
  assert.equal(failed.status, 'failed');
});

for (const phase of ['headers', 'body']) {
  test(`webhook deadline also bounds a blocked ${phase} without retry`, async () => {
    let expire;
    let cleared = 0;
    let attempts = 0;
    let signal;
    const pending = postWebhook('https://deploy.invalid/hook?token=secret', {
      setTimeoutImpl: (callback) => { expire = callback; return 42; },
      clearTimeoutImpl: (id) => { assert.equal(id, 42); cleared += 1; },
      fetchImpl: async (_url, options) => {
        attempts += 1;
        signal = options.signal;
        assert.equal(options.redirect, 'error');
        if (phase === 'headers') return new Promise(() => {});
        return { status: 200, text: () => new Promise(() => {}) };
      },
    });
    await Promise.resolve();
    expire();
    await assert.rejects(pending, /Webhook request timed out/);
    assert.equal(signal.aborted, true);
    assert.equal(cleared, 1);
    assert.equal(attempts, 1);
  });
}

test('webhook errors never repeat the secret URL or response body', async () => {
  const url = 'https://deploy.invalid/hook?token=private-token';
  for (const fetchImpl of [
    async () => { throw new Error(url); },
    async () => new Response(url, { status: 503 }),
    async () => ({ status: 200, text: async () => { throw new Error(url); } }),
  ]) {
    await assert.rejects(postWebhook(url, { fetchImpl }), (error) => {
      assert.doesNotMatch(error.message, /private-token|deploy.invalid/);
      return true;
    });
  }
  await assert.rejects(postWebhook('malformed-private-token'), (error) => {
    assert.doesNotMatch(error.message, /private-token/);
    return true;
  });
});

test('deployment workflows use the blocking webhook and isolated tag decisions', async () => {
  const apiWorkflow = await readFile(
    join(repositoryRoot, '.github/workflows/build-deploy-api.yml'),
    'utf8',
  );
  const webWorkflow = await readFile(
    join(repositoryRoot, '.github/workflows/flutter-web-build.yml'),
    'utf8',
  );

  assert.match(
    apiWorkflow,
    /release-artifact-check\.mjs post-webhook EASYPANEL_WEBHOOK/,
  );
  assert.doesNotMatch(apiWorkflow, /webhook returned non-2xx.*warning/i);
  assert.match(webWorkflow, /release-artifact-check\.mjs web-tags/);
  assert.match(
    webWorkflow,
    /release-artifact-check\.mjs post-webhook EASYPANEL_DEPLOY_URL/,
  );
  assert.doesNotMatch(webWorkflow, /tags=\(-t "\$IMAGE_NAME:latest"/);
});
