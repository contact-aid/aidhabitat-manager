import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';

test('the actual API app refuses GET/HEAD public roots without breaking liveness', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'aidhabitat-api-surface-test-'));
  // Isolate startup caches, dotenv lookup and credentials. No business backend
  // or SMTP credentials are inherited by the real Express app under test.
  const script = `
    import assert from 'node:assert/strict';
    const nativeFetch = globalThis.fetch;
    globalThis.fetch = (url, options) => {
      assert.equal(new URL(url).hostname, '127.0.0.1', 'Remote requests forbidden');
      return nativeFetch(url, options);
    };
    const { default: app } = await import(${JSON.stringify(new URL('./index.mjs', import.meta.url).href)});
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.on('listening', resolve));
    try {
      const base = 'http://127.0.0.1:' + server.address().port;
      for (const method of ['GET', 'HEAD']) {
        for (const pathname of ['/', '/openapi.json']) {
          const response = await fetch(base + pathname, { method, signal: AbortSignal.timeout(5000) });
          assert.equal(response.status, 404, method + ' ' + pathname);
          assert.match(response.headers.get('content-type'), /application\\/json/);
          if (method === 'GET') assert.deepEqual(await response.json(), { success: false, error: 'Not Found' });
          else assert.equal(await response.text(), '');
        }
      }
      const live = await fetch(base + '/api/health/live', { signal: AbortSignal.timeout(5000) });
      assert.equal(live.status, 200);
      assert.equal((await live.json()).status, 'live');
      for (const method of ['GET', 'POST']) {
        const response = await fetch(base + '/api/admin/data-retention', { method, signal: AbortSignal.timeout(5000) });
        assert.equal(response.status, 401, method + ' retention requires a session');
      }
      console.log('PUBLIC_SURFACE_PASS');
    } finally { await new Promise(resolve => server.close(resolve)); }
  `;
  const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', script], {
    cwd: root,
    env: {
      PATH: process.env.PATH,
      NODE_ENV: 'test',
      AIDHABITAT_API_ONLY: '1',
      AIDHABITAT_DATA_DIR_PATH: root,
      AUTH_SESSION_SECRET: 'synthetic-public-surface-test-secret-only',
    },
    timeout: 20000,
    maxBuffer: 100000,
  });
  assert.match(stdout, /PUBLIC_SURFACE_PASS/);
});
