import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createGuardedMutation, SyncMutationError } from './guardedMutation.mjs';
import { ConditionalWriteUncertainError } from './nocodbConditionalWrite.mjs';
import { inspectLegacyRecovery } from './legacySyncRecovery.mjs';

// Characterization of existing release blockers, not an integration test.
// Never import index.mjs: its warmup can contact configured remote services.
const source = readFileSync(new URL('./index.mjs', import.meta.url), 'utf8');
function fragment(start, end) {
  const a = source.indexOf(start);
  const b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `Source boundaries changed: ${start}`);
  assert.equal(source.indexOf(start, a + start.length), -1);
  return source.slice(a, b);
}
function evaluate(code, dependencies) {
  return new Function(...Object.keys(dependencies), code)(...Object.values(dependencies));
}
function response() {
  return {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}
const writeId = '11111111-1111-4111-8111-111111111111';
const revision = '22222222-2222-4222-8222-222222222222';
const timestamp = '2026-09-10T08:00:00.000Z';

function fixture(enabled = true) {
  const writes = [];
  const record = { id: '1', fields: {
    uuid_source: 'synthetic-dossier', patient_id: 'synthetic-patient',
    status: 'before', updated_at: timestamp, app_sync_revision: revision,
  } };
  const dependencies = {
    conditionalSyncEnabled: enabled,
    TABLES: { dossiers: 'synthetic_table' },
    SyncMutationError,
    inspectLegacyRecovery,
    unwrapRecordFields: (row) => row.fields,
    ConditionalWriteUncertainError,
    field: (row, key) => row.fields[key],
    canAccessDossierRecord: () => true,
    ensureDossierRecord: async () => record,
    getRecordUpdatedAt: (row) => row.fields.updated_at,
    nullableString: (value) => value === undefined ? undefined : value || null,
    sanitizeUndefined: (fields) => Object.fromEntries(
      Object.entries(fields).filter(([, value]) => value !== undefined)),
    resolveRequestedErgoLabel: async (_user, value) => value,
    upsertContexte: async (...args) => writes.push({ kind: 'context', args }),
    updateRecord: async (...args) => writes.push({ kind: 'legacy', args }),
    guardedMutation: enabled ? createGuardedMutation({
      readRecord: async () => ({ ...record.fields }),
      writer: async (input) => {
        writes.push({ kind: 'conditional', input });
        return { status: 'applied' };
      },
    }) : null,
  };
  dependencies.recoverLegacySync = evaluate(
    `${fragment('function recoverLegacySync(', 'const sendConflictIfStale =')}; return recoverLegacySync;`,
    dependencies,
  );
  dependencies.sendConflictIfStale = evaluate(
    `${fragment('const sendConflictIfStale =', 'const normalizeLabelForMatch =')}; return sendConflictIfStale;`,
    dependencies,
  );
  dependencies.applyConditionalSync = evaluate(
    `${fragment('async function applyConditionalSync(', 'const VISIT_RECOMMENDATION_FIELDS =')}; return applyConditionalSync;`,
    dependencies,
  );
  let handler;
  evaluate(fragment("app.patch('/api/dossiers/:dossierId'", "app.patch('/api/logements/by-beneficiary/:beneficiaryId'"), {
    ...dependencies,
    requireAuth: () => {},
    app: { patch: (_path, _auth, callback) => { handler = callback; } },
  });
  let errorHandler;
  evaluate(fragment('app.use((error, _req, res, _next) => {', 'const isDirectExecution ='), {
    app: { use: (callback) => { errorHandler = callback; } },
    console: { error() {} },
  });
  return {
    writes,
    record,
    errorHandler,
    async request(body) {
      const res = response();
      let error;
      await handler({ body, params: { dossierId: 'synthetic-dossier' },
        appUser: {}, get: () => undefined }, res, (caught) => {
        error = caught;
        errorHandler(caught, {}, res, () => {});
      });
      return { res, error };
    },
  };
}

test('flag on: legacy dossier PATCH receives 428 and performs no write', async () => {
  const f = fixture();
  const { res } = await f.request({ status: 'after', expectedUpdatedAt: timestamp });
  assert.equal(res.statusCode, 428);
  assert.equal(res.body.error, 'SYNC_BASELINE_REQUIRED');
  assert.deepEqual(f.writes, []);
});

test('flag on: baseline without durable writeId receives 428', async () => {
  const f = fixture();
  const { res } = await f.request({ status: 'after',
    concurrency: { version: 1, baseValues: { status: 'before' } } });
  assert.equal(res.statusCode, 428);
  assert.equal(res.body.error, 'SYNC_MUTATION_ID_REQUIRED');
  assert.deepEqual(f.writes, []);
});

test('flag on: context-only legacy PATCH bypasses the conditional writer', async () => {
  const f = fixture();
  // Two context versions are both accepted with the same dossier timestamp.
  for (const pathology of ['first', 'stale-second']) {
    const { res } = await f.request({ medicalContext: { pathology }, expectedUpdatedAt: timestamp });
    assert.equal(res.statusCode, 200);
  }
  assert.deepEqual(f.writes.map((entry) => entry.kind), ['context', 'context']);
  assert.equal(f.record.fields.updated_at, timestamp);
});

test('flag on: legacy mixed dossier/context PATCH stops at the missing baseline', async () => {
  const f = fixture();
  const { res } = await f.request({ status: 'after', medicalContext: { pathology: 'new' } });
  assert.equal(res.statusCode, 428);
  assert.deepEqual(f.writes, []);
});

test('guarded context is unsupported but preserves HTTP 400 after parent fix', async () => {
  const f = fixture();
  const { res, error } = await f.request({ medicalContext: { pathology: 'new' },
    concurrency: { version: 1, writeId, baseValues: {} } });
  assert.equal(error.code, 'SYNC_MULTITABLE_MUTATION_UNSUPPORTED');
  assert.equal(error.status, 400);
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'SYNC_MULTITABLE_MUTATION_UNSUPPORTED');
  assert.deepEqual(f.writes, []);
});

test('global middleware preserves SyncMutationError HTTP status after parent fix', () => {
  const f = fixture();
  for (const status of [400, 428, 503]) {
    const res = response();
    f.errorHandler(new SyncMutationError(status, 'SYNTHETIC_ONLY'), {}, res, () => {});
    assert.equal(res.statusCode, status);
  }
});

test('flag off: extra v1 metadata is accepted and legacy write path remains active', async () => {
  const f = fixture(false);
  const { res } = await f.request({ status: 'after', expectedUpdatedAt: timestamp,
    concurrency: { version: 1, writeId, baseValues: { status: 'before' } } });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(f.writes, [{ kind: 'legacy', args: ['synthetic_table', '1', { status: 'after' }] }]);
});

test('flag off: stale timestamp still rejects v1 payload despite independent baseline', async () => {
  const f = fixture(false);
  const { res } = await f.request({ status: 'after', expectedUpdatedAt: '2026-09-09T08:00:00.000Z',
    concurrency: { version: 1, writeId, baseValues: { status: 'before' } } });
  assert.equal(res.statusCode, 409);
  assert.deepEqual(f.writes, []);
});

test('flag on: prepared scalar dossier PATCH reaches conditional writer', async () => {
  const f = fixture();
  const { res } = await f.request({ status: 'after',
    concurrency: { version: 1, writeId, baseValues: { status: 'before' } } });
  assert.equal(res.statusCode, 200);
  assert.equal(f.writes.length, 1);
  assert.equal(f.writes[0].kind, 'conditional');
  assert.equal(f.writes[0].input.expectedRevision, revision);
});
