import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

for (const entity of ['dossier', 'beneficiaire', 'logement']) {
  test(`real Express conditional PATCH ${entity}`, { timeout: 45000 }, async (t) => {
    const root = await mkdtemp(path.join(tmpdir(), 'aidhabitat-conditional-http-'));
    try {
      const { stdout, stderr } = await promisify(execFile)(process.execPath, [
        fileURLToPath(new URL('./test-fixtures/conditionalRoutes.runner.mjs', import.meta.url)), entity,
      ], {
        cwd: root,
        // Deliberately inherit no dotenv, backend, SMTP, session or NODE_OPTIONS settings.
        env: {
          NODE_ENV: 'test',
          AIDHABITAT_API_ONLY: '1',
          AIDHABITAT_DATA_DIR_PATH: root,
          AIDHABITAT_CONDITIONAL_SYNC: '1',
          AUTH_SESSION_SECRET: 'synthetic-conditional-http-session-secret',
          NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
          NOCODB_BASE_ID: 'conditional_http_base',
          NOCODB_FORCE_REST: '1',
          NOCODB_REST_TIMEOUT_MS: '5000',
          AIRTABLE_TOKEN: 'synthetic-airtable-read-only-token',
        },
        timeout: 40000,
        maxBuffer: 200000,
      });
      assert.match(stdout, /CONDITIONAL_ROUTES_PASS/);
      t.diagnostic(stdout.split('\n').filter((line) => /^(PASS |CONDITIONAL_ROUTES_PASS)/.test(line)).join('\n'));
      if (stderr.trim()) t.diagnostic(stderr.trim());
    } catch (error) {
      assert.fail(`${entity} HTTP integration failed (${error.code || error.message})\n${error.stdout || ''}\n${error.stderr || ''}`);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
}
