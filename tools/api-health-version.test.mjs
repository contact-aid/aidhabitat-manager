import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const sha = 'abcdef01'.repeat(5);
for (const [name, rawSha, expectedSha] of [
  ['full SHA', sha, sha],
  ['uppercase full SHA with surrounding whitespace', ` ${sha.toUpperCase()} `, sha],
  ['missing SHA', undefined, null],
  ['short SHA', sha.slice(0, 12), null],
  ['unsafe environment contents', 'https://user:SYNTHETIC_SECRET@private.invalid/hook', null],
]) {
  test(`real public health handlers: ${name}`, { timeout: 15000 }, async () => {
    const root = await mkdtemp(join(tmpdir(), 'aidhabitat-health-version-'));
    const script = `
      import assert from 'node:assert/strict';
      import { once } from 'node:events';
      import { setImmediate } from 'node:timers/promises';
      import { createRestMock, origin } from ${JSON.stringify(new URL('../server/test-fixtures/conditionalRoutes.rest.mjs', import.meta.url).href)};
      import { waitForApiReadiness } from ${JSON.stringify(new URL('./wait-api-readiness.mjs', import.meta.url).href)};
      const expectedSha = ${JSON.stringify(expectedSha)};
      const mock = createRestMock();
      const nativeFetch = globalThis.fetch;
      let apiOrigin;
      let backendAvailable = true;
      globalThis.fetch = (input, options = {}) => {
        const url = new URL(input);
        if (apiOrigin && url.origin === apiOrigin) return nativeFetch(input, { ...options, redirect: 'manual' });
        assert.equal(url.origin, origin, 'External connections forbidden');
        if (!backendAvailable) throw new Error('Backend error contains SYNTHETIC_SECRET');
        return mock.fetch(input, options);
      };
      const { default: app } = await import(${JSON.stringify(new URL('../server/index.mjs', import.meta.url).href)});
      const server = app.listen(0, '127.0.0.1');
      await once(server, 'listening');
      await setImmediate();
      apiOrigin = 'http://127.0.0.1:' + server.address().port;
      try {
        mock.reset();
        const read = async (path, status, phase) => {
          const response = await fetch(apiOrigin + path, { signal: AbortSignal.timeout(3000) });
          assert.equal(response.status, status);
          assert.equal(response.headers.get('cache-control'), 'no-store');
          const text = await response.text();
          assert.doesNotMatch(text, /SYNTHETIC_SECRET|private.invalid|Backend error/);
          assert.deepEqual(JSON.parse(text), {
            success: status === 200, status: phase, buildSha: expectedSha,
            message: status === 200 ? 'OK' : 'Not ready',
          });
        };
        await read('/api/health/live', 200, 'live');
        assert.equal(mock.calls.length, 0, 'Liveness must not call the backend');
        await read('/api/health/ready', 200, 'ready');
        assert(mock.calls.length > 0, 'Readiness must check the backend');
        await read('/api/health', 200, 'ready');
        if (expectedSha) {
          const result = await waitForApiReadiness({ baseUrl: apiOrigin, expectedSha, timeoutMs: 3000 });
          assert.equal(result.buildSha, expectedSha);
          assert.equal(result.attempts, 1);
        }
        backendAvailable = false;
        await read('/api/health/ready', 503, 'not_ready');
        await read('/api/health', 503, 'not_ready');
        await read('/api/health/live', 200, 'live');
        assert.deepEqual(mock.violations, []);
        console.log('HEALTH_VERSION_PASS');
      } finally {
        await new Promise(resolve => server.close(resolve));
      }
    `;
    try {
      const { stdout } = await promisify(execFile)(process.execPath, ['--input-type=module', '-e', script], {
        cwd: root,
        env: {
          NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
          AUTH_SESSION_SECRET: 'synthetic-public-health-session-secret',
          NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
          NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1',
          ...(rawSha === undefined ? {} : { APP_BUILD_SHA: rawSha }),
        },
        timeout: 10000, maxBuffer: 100000,
      });
      assert.match(stdout, /HEALTH_VERSION_PASS/);
    } catch (error) {
      assert.fail(`Health integration failed (${error.code})\n${error.stdout || ''}\n${error.stderr || ''}`);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
}
