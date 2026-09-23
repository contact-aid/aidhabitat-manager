import assert from 'node:assert/strict';
import test from 'node:test';

import {
  createConcurrencyGate,
  executeSyncBatch,
  validateSyncBatchPayload,
} from './syncBatch.mjs';

test('validateSyncBatchPayload accepte uniquement les mutations légères', () => {
  const operations = validateSyncBatchPayload({
    operations: [
      {
        id: 'op-1',
        method: 'patch',
        path: '/api/dossiers/dossier-1',
        body: { status: 'À visiter' },
      },
      {
        id: 'op-2',
        method: 'PUT',
        path: '/api/mesures/dossier-1',
        body: { deboutHauteurCoude: '104' },
      },
      {
        id: 'diagnostic-1',
        method: 'PUT',
        path: '/api/diagnostic-sanitaires/dossier-1',
        body: { sdbInstances: [], wcInstances: [] },
      },
    ],
  });

  assert.equal(operations.length, 3);
  assert.equal(operations[0].method, 'PATCH');
});

test('validateSyncBatchPayload autorise la mise à jour du contexte de vie', () => {
  const [operation] = validateSyncBatchPayload({
    operations: [
      {
        id: 'context-1',
        method: 'PUT',
        path: '/api/contextes/dossier-1',
        body: {
          updates: { autonomy: { preparationRepas: true } },
          concurrency: {
            version: 1,
            reference: { recordId: 26, revision: 'revision-1' },
          },
        },
      },
    ],
  });

  assert.equal(operation.method, 'PUT');
  assert.equal(operation.path, '/api/contextes/dossier-1');
});

test('toutes les mutations JSON du relevé de visite restent autorisées', () => {
  const routes = [
    ['PATCH', '/api/dossiers/dossier-1'],
    ['PATCH', '/api/beneficiaires/patient-1'],
    ['PATCH', '/api/logements/by-beneficiary/patient-1'],
    ['PUT', '/api/contextes/dossier-1'],
    ['PUT', '/api/mesures/dossier-1'],
    ['PUT', '/api/observations/dossier-1'],
    ['PUT', '/api/diagnostic-sanitaires/dossier-1'],
  ];

  for (const [method, path] of routes) {
    const [operation] = validateSyncBatchPayload({
      operations: [{ id: `${method}-${path}`, method, path, body: {} }],
    });
    assert.equal(operation.method, method);
    assert.equal(operation.path, path);
  }
});

test('validateSyncBatchPayload refuse fichiers, rapports et doublons', () => {
  assert.throws(
    () =>
      validateSyncBatchPayload({
        operations: [
          {
            id: 'op-1',
            method: 'POST',
            path: '/api/mobile-documents',
            body: { bytes: 'base64' },
          },
        ],
      }),
    /Route non autorisée/,
  );
  assert.throws(
    () =>
      validateSyncBatchPayload({
        operations: [
          { id: 'same', method: 'PATCH', path: '/api/dossiers/1', body: {} },
          { id: 'same', method: 'PATCH', path: '/api/dossiers/2', body: {} },
        ],
      }),
    /dupliqué/,
  );
  assert.throws(
    () =>
      validateSyncBatchPayload({
        operations: Array.from({ length: 4 }, (_, index) => ({
          id: `op-${index}`,
          method: 'PATCH',
          path: `/api/dossiers/${index}`,
          body: {},
        })),
      }),
    /dépasse 3 opérations/,
  );
});

test('executeSyncBatch conserve l’ordre et isole les statuts', async () => {
  const calls = [];
  const results = await executeSyncBatch({
    operations: [
      { id: 'a', method: 'PATCH', path: '/api/dossiers/1', body: { a: 1 } },
      { id: 'b', method: 'PATCH', path: '/api/dossiers/2', body: { b: 2 } },
    ],
    origin: 'http://127.0.0.1:3001',
    sessionToken: 'session',
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options });
      const status = calls.length === 1 ? 200 : 409;
      return new Response(JSON.stringify({ success: status === 200 }), {
        status,
        headers: { 'content-type': 'application/json' },
      });
    },
  });

  assert.deepEqual(calls.map((call) => call.url), [
    'http://127.0.0.1:3001/api/dossiers/1',
    'http://127.0.0.1:3001/api/dossiers/2',
  ]);
  assert.equal(calls[0].options.headers['X-App-Session'], 'session');
  assert.deepEqual(results.map((result) => result.status), [200, 409]);
});

test('createConcurrencyGate plafonne les lots simultanés', async () => {
  const run = createConcurrencyGate(2);
  let active = 0;
  let peak = 0;
  const task = () =>
    run(async () => {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 10));
      active -= 1;
    });

  await Promise.all([task(), task(), task(), task()]);
  assert.equal(peak, 2);
});
