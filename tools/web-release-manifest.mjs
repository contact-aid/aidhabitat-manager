#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

function required(value, label) {
  const normalized = String(value ?? '').trim();
  if (!normalized) throw new Error(`Missing ${label}`);
  return normalized;
}

function validateGitSha(value) {
  const sha = required(value, 'git SHA').toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(sha)) throw new Error('Git SHA must contain 40 hexadecimal characters');
  return sha;
}

function validateApiBaseUrl(value) {
  const raw = required(value, 'API base URL');
  const parsed = new URL(raw);
  if (parsed.protocol !== 'https:' || parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error('API base URL must be an HTTPS URL without credentials, query or fragment');
  }
  return parsed.toString().replace(/\/$/, '');
}

export async function createWebReleaseManifest({
  buildDirectory,
  gitSha,
  apiBaseUrl,
  createdAt = new Date().toISOString(),
}) {
  const directory = path.resolve(required(buildDirectory, 'build directory'));
  const version = JSON.parse(await readFile(path.join(directory, 'version.json'), 'utf8'));
  const mainBytes = await readFile(path.join(directory, 'main.dart.js'));
  const appVersion = required(version.version ?? version.frameworkVersion, 'application version');
  const buildNumber = required(version.build_number ?? version.buildNumber, 'build number');
  const manifest = {
    schemaVersion: 1,
    gitSha: validateGitSha(gitSha),
    appVersion,
    buildNumber,
    apiBaseUrl: validateApiBaseUrl(apiBaseUrl),
    mainDartSha256: sha256(mainBytes),
    createdAt,
  };
  const target = path.join(directory, 'release.json');
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
  await rename(temporary, target);
  return manifest;
}

function readArg(args, name) {
  const index = args.indexOf(name);
  return index === -1 ? '' : args[index + 1] ?? '';
}

async function main(args) {
  if (args[0] !== 'write') {
    throw new Error('Usage: web-release-manifest.mjs write --dir <build/web> --git-sha <sha> --api-base-url <url>');
  }
  const manifest = await createWebReleaseManifest({
    buildDirectory: readArg(args, '--dir'),
    gitSha: readArg(args, '--git-sha'),
    apiBaseUrl: readArg(args, '--api-base-url'),
  });
  console.log(JSON.stringify(manifest));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`[web-release-manifest] ${error.message}`);
    process.exitCode = 1;
  });
}
