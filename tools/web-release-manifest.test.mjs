import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createWebReleaseManifest } from './web-release-manifest.mjs';

test('writes provenance from the exact web bundle', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'web-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(
    path.join(directory, 'version.json'),
    JSON.stringify({ app_name: 'aid_habitat_app', version: '1.0.0', build_number: '19' }),
  );
  await writeFile(path.join(directory, 'main.dart.js'), 'synthetic-main');

  const manifest = await createWebReleaseManifest({
    buildDirectory: directory,
    gitSha: '9c6a9cfa813686c972c667aa80ae5192e402ffaa',
    apiBaseUrl: 'https://api.aidhabitat.fr/',
    createdAt: '2026-09-14T08:00:00.000Z',
  });

  assert.equal(manifest.buildNumber, '19');
  assert.equal(manifest.apiBaseUrl, 'https://api.aidhabitat.fr');
  assert.match(manifest.mainDartSha256, /^[a-f0-9]{64}$/);
  assert.deepEqual(
    JSON.parse(await readFile(path.join(directory, 'release.json'), 'utf8')),
    manifest,
  );
});

test('rejects untraceable SHA and unsafe API target', async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'web-release-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(
    path.join(directory, 'version.json'),
    JSON.stringify({ version: '1.0.0', build_number: '19' }),
  );
  await writeFile(path.join(directory, 'main.dart.js'), 'synthetic-main');

  await assert.rejects(
    createWebReleaseManifest({
      buildDirectory: directory,
      gitSha: 'short',
      apiBaseUrl: 'https://api.aidhabitat.fr',
    }),
    /40 hexadecimal/,
  );
  await assert.rejects(
    createWebReleaseManifest({
      buildDirectory: directory,
      gitSha: '9c6a9cfa813686c972c667aa80ae5192e402ffaa',
      apiBaseUrl: 'https://user:secret@api.aidhabitat.fr',
    }),
    /without credentials/,
  );
});
