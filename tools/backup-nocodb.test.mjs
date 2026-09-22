import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import test from 'node:test';

const script = fileURLToPath(new URL('./backup-nocodb.mjs', import.meta.url));

async function runBackup(url, dir) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [script], {
      env: {
        ...process.env,
        NOCODB_API_URL: url,
        NOCODB_API_TOKEN: 'test-token',
        NOCODB_BASE_ID: 'test-base',
        BACKUP_DIR: dir,
        RETENTION_DAYS: '36500',
        PAGE_SIZE: '25',
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let output = '';
    child.stdout.on('data', chunk => { output += chunk; });
    child.stderr.on('data', chunk => { output += chunk; });
    child.on('error', reject);
    child.on('close', code => resolve({ code, output }));
  });
}

test('streaming backup writes complete paginated JSON and removes a failed partial file', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'aidhabitat-backup-test-'));
  let failOnSecondPage = false;
  const server = createServer((req, res) => {
    res.setHeader('Content-Type', 'application/json');
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/v2/meta/bases/test-base/tables') {
      res.end(JSON.stringify({ list: [{ id: 'table-1', title: 'Fixture' }] }));
    } else if (url.pathname === '/api/v2/meta/tables/table-1') {
      res.end(JSON.stringify({ columns: [{ id: 'col-1', title: 'value', uidt: 'LongText' }] }));
    } else if (url.pathname === '/api/v2/tables/table-1/records') {
      const offset = Number(url.searchParams.get('offset'));
      if (failOnSecondPage && offset === 25) {
        res.statusCode = 500;
        res.end(JSON.stringify({ error: 'synthetic' }));
      } else {
        const count = offset === 0 ? 25 : 1;
        res.end(JSON.stringify({ list: Array.from({ length: count }, (_, i) => ({ Id: offset + i + 1, value: `item-${offset + i + 1}` })) }));
      }
    } else {
      res.statusCode = 404;
      res.end('{}');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    const success = await runBackup(url, dir);
    assert.equal(success.code, 0, success.output);
    let files = await readdir(dir);
    assert.equal(files.length, 1);
    const file = join(dir, files[0]);
    assert.equal((await stat(file)).mode & 0o777, 0o600);
    const dump = JSON.parse(gunzipSync(await readFile(file)));
    assert.equal(dump.version, 1);
    assert.equal(dump.baseId, 'test-base');
    assert.equal(dump.tables.length, 1);
    assert.equal(dump.tables[0].records.length, 26);
    assert.deepEqual(dump.tables[0].records[25], { Id: 26, value: 'item-26' });

    failOnSecondPage = true;
    const failure = await runBackup(url, dir);
    assert.equal(failure.code, 1);
    files = await readdir(dir);
    assert.deepEqual(files, [files[0]]);
    assert.equal(files[0], file.split('/').at(-1));
  } finally {
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  }
});
