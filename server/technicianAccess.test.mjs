import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
import { TECHNICIAN_PROFILES, isTechnicianEmail } from './technicianProfiles.mjs';

test('technician identities use the confirmed domain and never alias the administrator', () => {
  assert.equal(Object.keys(TECHNICIAN_PROFILES).length, 3);
  assert(isTechnicianEmail(' AG.ROZEC@AIDHABITAT.FR '));
  assert(!isTechnicianEmail('ag.rozec@aidhabitation.fr'));
  assert(!isTechnicianEmail('contact@aidhabitat.fr'));
});

if (process.argv.includes('--runner')) await run();
else test('three technician accounts authenticate and cannot access another workspace or admin actions', { timeout: 45000 }, async () => {
  const root = await mkdtemp(`${tmpdir()}/technician-access-`);
  try {
    const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
      cwd: root, timeout: 40000, maxBuffer: 200000,
      env: { NODE_ENV: 'test', AIDHABITAT_API_ONLY: '1', AIDHABITAT_DATA_DIR_PATH: root,
        AUTH_SESSION_SECRET: 'synthetic-technician-session-secret',
        NOCODB_API_URL: 'https://nocodb.test.invalid', NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
        NOCODB_BASE_ID: 'conditional_http_base', NOCODB_FORCE_REST: '1' },
    });
    assert.match(stdout, /TECHNICIAN_ACCESS_PASS/);
  } catch (e) { assert.fail(`${e.stdout}\n${e.stderr || e.message}`); }
  finally { await rm(root, { recursive: true, force: true }); }
});

async function run() {
  const { createRestMock, tables, dossierId, password } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const base = createRestMock(); const added = [];
  let origin; const nativeFetch = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (url.origin === origin) return nativeFetch(input, init);
    if (url.pathname === `/api/v2/tables/${tables.dossier}/records` && init.method === 'PATCH') {
      assert.equal(url.origin, 'https://nocodb.test.invalid');
      const patch = JSON.parse(init.body)[0];
      assert.equal(patch.Id, base.row('dossier').Id);
      Object.assign(base.row('dossier'), patch);
      return Response.json([base.row('dossier')]);
    }
    if (url.pathname === `/api/v2/tables/${tables.ergos}/records`) {
      assert.equal(url.origin, 'https://nocodb.test.invalid');
      if (init.method === 'POST') {
        const row = { Id: 10 + added.length, ...JSON.parse(init.body) };
        added.push(row);
        return Response.json(row);
      }
      if ((init.method || 'GET') === 'GET') {
        const response = await base.fetch(input, init); const body = await response.json();
        body.list.push(...structuredClone(added));
        body.pageInfo.totalRows += added.length;
        return Response.json(body);
      }
    }
    return base.fetch(input, init);
  };
  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  origin = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, token, body, method = body ? 'POST' : 'GET') => {
    const r = await fetch(origin + path, { method, headers: { 'content-type': 'application/json', ...(token ? { 'x-app-session': token } : {}) }, body: body ? JSON.stringify(body) : undefined });
    return { status: r.status, body: await r.json() };
  };
  try {
    const admin = await request('/api/auth/login', null, { email: 'contact@aidhabitat.fr', password });
    assert.equal(admin.status, 200); const adminToken = admin.body.data.token;
    const technicianPassword = `${password}7`;
    for (const [email, profile] of Object.entries(TECHNICIAN_PROFILES)) {
      const created = await request('/api/admin/access-members', adminToken,
        { email, displayName: profile.displayName, role: 'TECHNICIAN', establishmentId: 2, password: technicianPassword });
      assert.equal(created.status, 201, JSON.stringify(created.body));
      assert.equal(created.body.data.member.role, 'TECHNICIAN');
      const login = await request('/api/auth/login', null, { email, password: technicianPassword });
      assert.equal(login.status, 200, JSON.stringify(login.body));
      const token = login.body.data.token;
      const members = await request('/api/admin/access-members', token);
      assert.equal(members.status, 403);
      assert.equal((await request(`/api/mesures/${dossierId}`, token)).status, 403);
      base.row('dossier').ergo_id = profile.displayName;
      const own = await request(`/api/dossiers/${dossierId}`, token, { status: 'A visiter' }, 'PATCH');
      assert.equal(own.status, 200, JSON.stringify(own.body));
      base.row('dossier').ergo_id = 'Test Owner';
      assert.equal((await request('/api/admin/access-members', adminToken,
        { email, displayName: profile.displayName, role: 'TECHNICIAN', password })).status, 409);
    }
    assert.equal(added.length, 3);
    assert.deepEqual(base.violations, []);
    console.log('TECHNICIAN_ACCESS_PASS');
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
}
