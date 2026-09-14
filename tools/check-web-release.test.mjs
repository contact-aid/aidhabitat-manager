import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const gitSha = '9c6a9cfa813686c972c667aa80ae5192e402ffaa';

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'web-check-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(path.join(directory, 'pdfjs'), { recursive: true });
  await mkdir(path.join(directory, 'icons'), { recursive: true });
  await writeFile(
    path.join(directory, 'index.html'),
    "<title>App'Ergo</title><script src='pdfjs/pdf.min.js'></script>" +
      '<script>const retireLegacyPwa = true;</script><script src="flutter_bootstrap.js"></script>',
  );
  await writeFile(
    path.join(directory, 'flutter_bootstrap.js'),
    'const asset = "main.dart.js"; _flutter.loader.load();',
  );
  await writeFile(
    path.join(directory, 'version.json'),
    JSON.stringify({ app_name: 'aid_habitat_app', version: '1.0.0', build_number: '19' }),
  );
  const main = Buffer.alloc(500_001, 1);
  await writeFile(path.join(directory, 'main.dart.js'), main);
  const assets = [
    ['flutter.js', 8_001],
    ['sqlite3.wasm', 100_001],
    ['sqflite_sw.js', 1_001],
    ['favicon.png', 501],
    ['pdfjs/pdf.min.js', 100_001],
    ['pdfjs/pdf.worker.min.js', 500_001],
    ['icons/Icon-192.png', 1_001],
    ['icons/Icon-512.png', 1_001],
    ['icons/Icon-maskable-192.png', 1_001],
    ['icons/Icon-maskable-512.png', 1_001],
  ];
  await Promise.all(
    assets.map(([name, size]) => writeFile(path.join(directory, name), Buffer.alloc(size, 1))),
  );
  await writeFile(
    path.join(directory, 'release.json'),
    JSON.stringify({
      schemaVersion: 1,
      gitSha,
      buildNumber: '19',
      mainDartSha256: createHash('sha256').update(main).digest('hex'),
    }),
  );
  return directory;
}

test('accepts only the expected build and exact bundle provenance', async (t) => {
  const directory = await fixture(t);
  const script = path.resolve('tools/check-web-release.mjs');
  const result = await execFileAsync(process.execPath, [
    script,
    '--dir',
    directory,
    '--expected-build-number',
    '19',
    '--expected-git-sha',
    gitSha,
  ]);
  assert.match(result.stdout, /web-release-check\] OK/);

  await assert.rejects(
    execFileAsync(process.execPath, [
      script,
      '--dir',
      directory,
      '--expected-build-number',
      '20',
      '--expected-git-sha',
      gitSha,
    ]),
    (error) => error.code === 1 && /build 19, 20 attendu/.test(error.stderr),
  );

  const releasePath = path.join(directory, 'release.json');
  const release = JSON.parse(await readFile(releasePath, 'utf8'));
  release.mainDartSha256 = '0'.repeat(64);
  await writeFile(releasePath, JSON.stringify(release));
  await assert.rejects(
    execFileAsync(process.execPath, [
      script,
      '--dir',
      directory,
      '--expected-build-number',
      '19',
      '--expected-git-sha',
      gitSha,
    ]),
    (error) => error.code === 1 && /empreinte main\.dart\.js incohérente/.test(error.stderr),
  );
});
