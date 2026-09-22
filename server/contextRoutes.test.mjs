import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { registerContextRoutes } from './contextRoutes.mjs';
import { contextRecordToSections, contextServerReference, contextSectionsToDatabaseFields } from './contextGuardedSync.mjs';

function fixture({ enabled = true, allowed = true, absent = false, creationReady = false } = {}) {
  const routes = new Map();
  let row = absent ? null : { Id: 11, dossier_id: 'dossier-1', app_sync_revision: randomUUID(),
    ...contextSectionsToDatabaseFields({ medicalContext: { pathology: 'initial' } }) };
  let writes = 0;
  let reads = 0;
  let duplicate = false;
  const dossier = { id: 1, uuid_source: 'dossier-1', patient_id: 'patient-1' };
  registerContextRoutes({
    get: (_url, _auth, handler) => routes.set('GET', handler),
    put: (_url, _auth, handler) => routes.set('PUT', handler),
  }, {
    requireAuth: () => {}, enabled, creationReady, tableId: 'contexts',
    ensureDossierRecord: async () => dossier,
    canAccessDossierRecord: () => allowed,
    field: (r, key) => r[key],
    queryAll: async () => { reads++; return row ? duplicate ? [row, row] : [structuredClone(row)] : []; },
    createRecord: async (_table, fields) => {
      assert.equal(row, null); writes++; row = { Id: 11, ...fields };
    },
    writer: async ({ expectedRevision, writeId, fields }) => {
      if (row.app_sync_revision !== expectedRevision) return { status: 'not_confirmed', reason: 'revision_changed' };
      writes++; Object.assign(row, fields, { app_sync_revision: writeId });
      return { status: 'applied', revision: writeId };
    },
  });
  return {
    dossier, row: () => row, writes: () => writes, reads: () => reads,
    duplicate: () => { duplicate = true; },
    guard: () => ({ version: 1, writeId: randomUUID(), reference: row ? contextServerReference(row) : null,
      baseValues: row ? contextRecordToSections(row) : {} }),
    request: async (method, body = {}) => {
      const res = { statusCode: 200, status(n) { this.statusCode = n; return this; }, json(b) { this.body = b; } };
      await routes.get(method)({ params: { dossierId: 'dossier-1' }, appUser: {}, body }, res,
        e => { res.statusCode = e.status ?? e.statusCode ?? 500; res.body = { error: e.code }; });
      return res;
    },
  };
}

test('context GET exposes its own revision even without a timestamp', async () => {
  const f = fixture();
  const r = await f.request('GET');
  assert.equal(r.statusCode, 200);
  assert.equal(r.body.serverReference.revision, f.row().app_sync_revision);
  assert.equal(r.body.medicalContext.pathology, 'initial');
});

test('parent write does not invalidate a context edit; stale context overwrite is rejected', async () => {
  const f = fixture();
  const guard = f.guard();
  f.dossier.updated_at = '2099-01-01T00:00:00Z';
  const update = pathology => ({ medicalContext: { ...guard.baseValues.medicalContext, pathology } });
  const first = await f.request('PUT', { updates: update('first'), concurrency: guard });
  assert.equal(first.statusCode, 200);
  assert.notEqual(first.body.data.serverReference.revision, guard.reference.revision);
  const second = await f.request('PUT', { updates: update('second'), concurrency: { ...guard, writeId: randomUUID() } });
  assert.equal(second.statusCode, 409);
  assert.equal(f.writes(), 1);
  assert.equal(contextRecordToSections(f.row()).medicalContext.pathology, 'first');
});

test('simultaneous conflicting writes cannot both overwrite the same context', async () => {
  const f = fixture(); const guard = f.guard();
  const results = await Promise.all(['first', 'second'].map(pathology => f.request('PUT', {
    updates: { medicalContext: { ...guard.baseValues.medicalContext, pathology } },
    concurrency: { ...guard, writeId: randomUUID() },
  })));
  assert.deepEqual(results.map(r => r.statusCode).sort(), [200, 409]);
  assert.equal(f.writes(), 1);
});

test('lost context ACK replay does not write twice', async () => {
  const f = fixture(); const concurrency = f.guard();
  const body = { concurrency, updates: { medicalContext: { ...concurrency.baseValues.medicalContext, pathology: 'new' } } };
  assert.equal((await f.request('PUT', body)).statusCode, 200);
  assert.equal((await f.request('PUT', body)).statusCode, 200);
  assert.equal(f.writes(), 1);
});

test('disabled and forbidden routes never read or write context', async () => {
  for (const [options, status] of [[{ enabled: false }, 503], [{ allowed: false }, 403]]) {
    const f = fixture(options);
    for (const method of ['GET', 'PUT']) assert.equal((await f.request(method)).statusCode, status);
    assert.equal(f.reads(), 0); assert.equal(f.writes(), 0);
  }
});

test('duplicate context or missing revision fails closed', async () => {
  const f = fixture(); f.duplicate();
  assert.equal((await f.request('GET')).statusCode, 503);
  const g = fixture(); delete g.row().app_sync_revision;
  assert.equal((await g.request('GET')).statusCode, 503);
});

test('context creation requires its own explicit preparation gate', async () => {
  for (const creationReady of [false, true]) {
    const f = fixture({ absent: true, creationReady });
    const body = { concurrency: f.guard(), updates: { medicalContext: { pathology: 'new' } } };
    const result = await f.request('PUT', body);
    assert.equal(result.statusCode, creationReady ? 200 : 503);
    assert.equal(f.writes(), creationReady ? 1 : 0);
  }
});
