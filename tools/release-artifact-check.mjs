#!/usr/bin/env node

import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const dockerTagPattern = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;
const shaPattern = /^[a-fA-F0-9]{7,64}$/;
const buildIdPattern = /^[A-Za-z0-9][A-Za-z0-9_.+-]{0,159}$/;

export class ReleaseCheckError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ReleaseCheckError';
  }
}

function required(value, label) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ReleaseCheckError(`${label} is required`);
  }
  return value.trim();
}

export function assertSuccessfulHttpStatus(status) {
  const numericStatus = Number(status);
  if (!Number.isInteger(numericStatus) || numericStatus < 200 || numericStatus >= 300) {
    throw new ReleaseCheckError(`Webhook returned HTTP ${status}`);
  }
  return numericStatus;
}

export async function postWebhook(
  url,
  {
    fetchImpl = globalThis.fetch,
    timeoutMs = 30_000,
    setTimeoutImpl = globalThis.setTimeout,
    clearTimeoutImpl = globalThis.clearTimeout,
  } = {},
) {
  let parsed;
  try {
    parsed = new URL(required(url, 'webhook URL'));
  } catch {
    throw new ReleaseCheckError('Invalid webhook URL');
  }
  if (!['https:', 'http:'].includes(parsed.protocol)) {
    throw new ReleaseCheckError('Webhook URL must use HTTP or HTTPS');
  }
  if (typeof fetchImpl !== 'function') {
    throw new ReleaseCheckError('No HTTP client is available');
  }
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs <= 0) {
    throw new ReleaseCheckError('Invalid webhook timeout');
  }

  const controller = new AbortController();
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeoutImpl(() => {
      const error = new ReleaseCheckError('Webhook request timed out');
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });
  try {
    return await Promise.race([
      deadline,
      (async () => {
        let response;
        let body;
        try {
          response = await fetchImpl(parsed, {
            method: 'POST',
            redirect: 'error',
            signal: controller.signal,
          });
        } catch {
          // Transport errors and response bodies may contain the secret URL.
          throw new ReleaseCheckError('Webhook network error');
        }
        assertSuccessfulHttpStatus(response.status);
        try {
          body = await response.text();
        } catch {
          throw new ReleaseCheckError('Webhook response could not be read');
        }
        return { status: response.status, body };
      })(),
    ]);
  } catch (error) {
    controller.abort();
    throw error;
  } finally {
    clearTimeoutImpl(timer);
  }
}

export function webImageTags({ imageName, imageTag, sha }) {
  const name = required(imageName, 'image name');
  const tag = required(imageTag, 'image tag');
  const commitSha = required(sha, 'commit SHA');
  if (!dockerTagPattern.test(tag)) {
    throw new ReleaseCheckError(`Invalid container tag: ${tag}`);
  }
  if (!shaPattern.test(commitSha)) {
    throw new ReleaseCheckError(`Invalid commit SHA: ${commitSha}`);
  }

  // The same commit can produce different bundles for different API targets.
  // Only production keeps the legacy bare-SHA alias.
  const versionTag = tag === 'latest' ? commitSha : `${tag}-${commitSha}`;
  if (!dockerTagPattern.test(versionTag)) {
    throw new ReleaseCheckError('Container channel tag is too long for a versioned tag');
  }
  return [...new Set([`${name}:${tag}`, `${name}:${versionTag}`])];
}

export function assertStagingTag(imageTag) {
  if (imageTag !== 'staging') {
    throw new ReleaseCheckError(
      `Staging deployment requires image_tag=staging, received ${imageTag}`,
    );
  }
}

export function createNativeBuildId({
  version,
  buildNumber,
  sha,
  dirty,
  timestamp = new Date(),
  nonce = process.pid,
}) {
  const shortSha = required(sha, 'commit SHA').slice(0, 12);
  const stamp = timestamp.toISOString().replaceAll(/[-:.]/g, '').replace('000Z', 'Z');
  const id = `${required(version, 'version')}+${required(buildNumber, 'build number')}-${shortSha}-${dirty ? 'dirty' : 'clean'}-${stamp}-${nonce}`;
  if (!buildIdPattern.test(id)) {
    throw new ReleaseCheckError(`Invalid generated build identifier: ${id}`);
  }
  return id;
}

export async function reserveArtifactDirectory(path) {
  const target = resolve(required(path, 'artifact directory'));
  await mkdir(dirname(target), { recursive: true });
  try {
    await mkdir(target);
  } catch (error) {
    if (error?.code === 'EEXIST') {
      throw new ReleaseCheckError(
        `Artifact directory already exists; refusing to overwrite it: ${target}`,
      );
    }
    throw error;
  }
  return target;
}

export function sanitizeApiTarget(value) {
  const parsed = new URL(required(value, 'API target'));
  if (parsed.protocol !== 'https:') {
    throw new ReleaseCheckError('Native release API target must use HTTPS');
  }
  if (parsed.username || parsed.password) {
    throw new ReleaseCheckError('API target must not contain credentials');
  }
  parsed.search = '';
  parsed.hash = '';
  return parsed.toString().replace(/\/$/, '');
}

export function buildNativeManifest(input) {
  return {
    schemaVersion: 1,
    status: input.status ?? 'started',
    buildId: required(input.buildId, 'build ID'),
    createdAt: required(input.createdAt, 'creation time'),
    source: {
      gitSha: required(input.gitSha, 'git SHA'),
      dirty: Boolean(input.dirty),
      dirtyReleaseExplicitlyAccepted: Boolean(input.dirtyAccepted),
    },
    application: {
      version: required(input.version, 'application version'),
      buildNumber: required(input.buildNumber, 'application build number'),
    },
    sdk: {
      flutter: required(input.flutterSdk, 'Flutter SDK'),
      dart: required(input.dartSdk, 'Dart SDK'),
      platform: required(input.platformSdk, 'platform SDK'),
    },
    target: {
      platform: required(input.platform, 'platform'),
      platformApi: required(input.platformApi, 'platform API'),
      backendApi: sanitizeApiTarget(input.backendApi),
    },
    artifacts: {
      symbolsDirectory: required(input.symbolsDirectory, 'symbols directory'),
    },
    checks: {
      sourceTreeClean: !input.dirty,
      artifactDirectoryReservedLocally: true,
      remoteBuildNumberVerified: false,
    },
    remainingRemoteVerification:
      'Confirm the version/build number in App Store Connect or the target store before upload.',
  };
}

async function writeJsonAtomically(path, value) {
  const target = resolve(path);
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, {
    encoding: 'utf8',
    flag: 'wx',
  });
  await rename(temporary, target);
}

export async function writeNativeManifest(path, input) {
  const manifest = buildNativeManifest(input);
  await writeJsonAtomically(path, manifest);
  return manifest;
}

export async function updateNativeManifestStatus(path, status) {
  if (!['completed', 'failed'].includes(status)) {
    throw new ReleaseCheckError(`Invalid build status: ${status}`);
  }
  const manifest = JSON.parse(await readFile(path, 'utf8'));
  manifest.status = status;
  manifest.finishedAt = new Date().toISOString();
  await writeJsonAtomically(path, manifest);
  return manifest;
}

function manifestInputFromEnvironment(env) {
  return {
    status: 'started',
    buildId: env.RELEASE_BUILD_ID,
    createdAt: env.RELEASE_CREATED_AT,
    gitSha: env.RELEASE_GIT_SHA,
    dirty: env.RELEASE_GIT_DIRTY === 'true',
    dirtyAccepted: env.RELEASE_DIRTY_ACCEPTED === 'true',
    version: env.RELEASE_APP_VERSION,
    buildNumber: env.RELEASE_BUILD_NUMBER,
    flutterSdk: env.RELEASE_FLUTTER_SDK,
    dartSdk: env.RELEASE_DART_SDK,
    platformSdk: env.RELEASE_PLATFORM_SDK,
    platform: env.RELEASE_PLATFORM,
    platformApi: env.RELEASE_PLATFORM_API,
    backendApi: env.RELEASE_BACKEND_API,
    symbolsDirectory: env.RELEASE_SYMBOLS_DIRECTORY,
  };
}

async function main(argv) {
  const [command, ...args] = argv;
  switch (command) {
    case 'post-webhook': {
      const envName = required(args[0], 'webhook environment variable');
      if (!/^[A-Z][A-Z0-9_]*$/.test(envName)) {
        throw new ReleaseCheckError('Invalid webhook environment variable name');
      }
      const result = await postWebhook(process.env[envName]);
      console.log(`Webhook accepted: HTTP ${result.status}`);
      return;
    }
    case 'web-tags':
      console.log(
        webImageTags({ imageName: args[0], imageTag: args[1], sha: args[2] }).join('\n'),
      );
      return;
    case 'assert-staging-tag':
      assertStagingTag(args[0]);
      return;
    case 'native-build-id':
      console.log(
        createNativeBuildId({
          version: args[0],
          buildNumber: args[1],
          sha: args[2],
          dirty: args[3] === 'true',
        }),
      );
      return;
    case 'reserve-directory':
      console.log(await reserveArtifactDirectory(args[0]));
      return;
    case 'write-native-manifest':
      await writeNativeManifest(args[0], manifestInputFromEnvironment(process.env));
      return;
    case 'update-native-status':
      await updateNativeManifestStatus(args[0], args[1]);
      return;
    default:
      throw new ReleaseCheckError(`Unknown release check command: ${command ?? '(none)'}`);
  }
}

// Node resolves symlinks for import.meta.url; macOS /var and /tmp are aliases.
const isCli = process.argv[1]
  && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
if (isCli) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`[release-check] ${error.message}`);
    process.exitCode = 1;
  });
}
