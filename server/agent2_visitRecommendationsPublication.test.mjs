import test from 'node:test';
import assert from 'node:assert/strict';

import {
  VisitRecommendationsPublicationError,
  createNocodbVisitRecommendationsSnapshotStore,
  createVisitRecommendationsPublisher,
  hashVisitRecommendationsRequest,
} from './visitRecommendationsPublication.mjs';

const revision = '00000000-0000-4000-8000-000000000001';
const writeOne = '00000000-0000-4000-8000-000000000002';
const writeTwo = '00000000-0000-4000-8000-000000000003';

const linkedItem = (id, wikiItemId = `wiki-${id}`) => ({
  id,
  wikiItemId,
  customTitle: `Titre ${id}`,
  note: `Note ${id}`,
});

const storedItem = (id, wikiItemId = `wiki-${id}`) => ({
  id,
  wikiItemId,
  wikiTitle: `Bibliotheque ${wikiItemId}`,
  wikiImageUrl: '',
  wikiTag: 'Salle de bain',
  wikiDescription: '',
  customTitle: `Titre ${id}`,
  note: `Note ${id}`,
  createdAt: '',
  updatedAt: '',
});

const envelope = (items, { writeId = writeOne, expectedRevision = revision } = {}) => ({
  protocolVersion: 1,
  writeId,
  expectedRevision,
  items,
});

const snapshot = (items = [storedItem('old')]) => ({
  dossierId: 'dossier-1',
  revision,
  lastWriteId: revision,
  requestHash: hashVisitRecommendationsRequest({ dossierId: 'dossier-1', items }),
  items,
  updatedAt: '2026-09-10T08:00:00.000Z',
});

const clone = (value) => value == null ? null : structuredClone(value);

const memoryStore = (initial, { interrupt = null } = {}) => {
  let current = clone(initial);
  let compareAndSwapCalls = 0;
  return {
    async read() {
      return clone(current);
    },
    async compareAndSwap({ expectedRevision, next }) {
      compareAndSwapCalls += 1;
      if (interrupt === 'before') throw new Error('connection lost before write');
      if ((current?.revision ?? null) !== expectedRevision) {
        return { status: 'revision_changed', snapshot: clone(current) };
      }
      current = clone(next);
      if (interrupt === 'after') throw new Error('response lost after write');
      return { status: 'applied', snapshot: clone(current) };
    },
    get current() {
      return clone(current);
    },
    get compareAndSwapCalls() {
      return compareAndSwapCalls;
    },
  };
};

const wikiResolver = async (wikiItemId) => wikiItemId === 'wiki-missing'
  ? null
  : {
      id: wikiItemId,
      title: `Bibliotheque ${wikiItemId}`,
      tags: ['Salle de bain'],
    };

const publisherFor = (store) => createVisitRecommendationsPublisher({
  store,
  resolveWikiItem: wikiResolver,
  now: () => '2026-09-10T09:00:00.000Z',
});

const errorCode = (code, status) => (error) => {
  assert.ok(error instanceof VisitRecommendationsPublicationError);
  assert.equal(error.code, code);
  assert.equal(error.status, status);
  return true;
};

test('agent2 total deletion atomically publishes an empty snapshot', async () => {
  const store = memoryStore(snapshot());
  const result = await publisherFor(store)({
    dossierId: 'dossier-1',
    envelope: envelope([]),
  });

  assert.equal(result.applied, true);
  assert.equal(result.replay, false);
  assert.deepEqual(result.snapshot.items, []);
  assert.deepEqual(store.current.items, []);
  assert.equal(store.compareAndSwapCalls, 1);
});

test('agent2 drafts are rejected at the server boundary without a write', async () => {
  const store = memoryStore(snapshot());

  await assert.rejects(
    publisherFor(store)({
      dossierId: 'dossier-1',
      envelope: envelope([{ id: 'draft', wikiItemId: '', note: 'local' }]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_DRAFT_NOT_PUBLISHABLE', 400),
  );
  assert.equal(store.compareAndSwapCalls, 0);
  assert.deepEqual(store.current.items, snapshot().items);
});

test('agent2 temporary local wiki ids are rejected before resolution', async () => {
  const store = memoryStore(snapshot());
  let resolverCalls = 0;
  const publish = createVisitRecommendationsPublisher({
    store,
    resolveWikiItem: async () => {
      resolverCalls += 1;
      return { id: 'should-not-be-used', title: 'Unexpected' };
    },
  });

  await assert.rejects(
    publish({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('temporary', 'local_draft_42')]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_WIKI_LINK_LOCAL_DRAFT', 409),
  );
  assert.equal(resolverCalls, 0);
  assert.equal(store.compareAndSwapCalls, 0);
});

test('agent2 a missing expectedRevision cannot be treated as initial creation', async () => {
  const store = memoryStore(null);
  const incomplete = envelope([linkedItem('new')], { expectedRevision: null });
  delete incomplete.expectedRevision;

  await assert.rejects(
    publisherFor(store)({ dossierId: 'dossier-1', envelope: incomplete }),
    errorCode('VISIT_RECOMMENDATIONS_REVISION_REQUIRED', 428),
  );
  assert.equal(store.compareAndSwapCalls, 0);
});

test('agent2 stale library links reject the whole replacement before writing', async () => {
  const store = memoryStore(snapshot());

  await assert.rejects(
    publisherFor(store)({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('valid'), linkedItem('stale', 'wiki-missing')]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_WIKI_LINK_STALE', 409),
  );
  assert.equal(store.compareAndSwapCalls, 0);
  assert.deepEqual(store.current.items, snapshot().items);
});

test('agent2 a lost success response is confirmed read-only and not repeated', async () => {
  const store = memoryStore(snapshot(), { interrupt: 'after' });
  const publish = publisherFor(store);
  const mutation = {
    dossierId: 'dossier-1',
    envelope: envelope([linkedItem('new')]),
  };

  const first = await publish(mutation);
  const replay = await publish(mutation);

  assert.equal(first.applied, true);
  assert.equal(first.replay, true);
  assert.equal(replay.replay, true);
  assert.equal(store.compareAndSwapCalls, 1);
  assert.deepEqual(store.current.items, [storedItem('new')]);
});

test('agent2 interruption before application remains unconfirmed and retryable', async () => {
  const store = memoryStore(snapshot(), { interrupt: 'before' });

  await assert.rejects(
    publisherFor(store)({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('new')]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_WRITE_UNCONFIRMED', 503),
  );
  assert.equal(store.compareAndSwapCalls, 1);
  assert.deepEqual(store.current.items, snapshot().items);
});

test('agent2 replay with the same write id and payload performs no second mutation', async () => {
  const store = memoryStore(snapshot());
  const publish = publisherFor(store);
  const mutation = {
    dossierId: 'dossier-1',
    envelope: envelope([linkedItem('new')]),
  };

  const first = await publish(mutation);
  const second = await publish(mutation);

  assert.equal(first.replay, false);
  assert.equal(second.replay, true);
  assert.equal(store.compareAndSwapCalls, 1);
});

test('agent2 reusing a write id for another payload is a conflict', async () => {
  const store = memoryStore(snapshot());
  const publish = publisherFor(store);
  await publish({
    dossierId: 'dossier-1',
    envelope: envelope([linkedItem('first')]),
  });

  await assert.rejects(
    publish({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('different')]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_WRITE_ID_REUSED', 409),
  );
  assert.equal(store.compareAndSwapCalls, 1);
});

test('agent2 two devices from one revision cannot overwrite each other', async () => {
  const store = memoryStore(snapshot());
  const publish = publisherFor(store);

  await publish({
    dossierId: 'dossier-1',
    envelope: envelope([linkedItem('device-a')], { writeId: writeOne }),
  });
  await assert.rejects(
    publish({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('device-b')], { writeId: writeTwo }),
    }),
    errorCode('VISIT_RECOMMENDATIONS_REVISION_CONFLICT', 409),
  );

  assert.deepEqual(store.current.items, [storedItem('device-a')]);
  assert.equal(store.compareAndSwapCalls, 1);
});

test('agent2 duplicate stable item ids reject the replacement', async () => {
  const store = memoryStore(snapshot());

  await assert.rejects(
    publisherFor(store)({
      dossierId: 'dossier-1',
      envelope: envelope([linkedItem('same'), linkedItem('same', 'wiki-other')]),
    }),
    errorCode('VISIT_RECOMMENDATIONS_DUPLICATE_ITEM_ID', 400),
  );
  assert.equal(store.compareAndSwapCalls, 0);
});

test('agent2 request hashing is independent of object key insertion order', () => {
  const left = hashVisitRecommendationsRequest({
    dossierId: 'dossier-1',
    items: [{ id: 'one', wikiItemId: 'wiki-one' }],
  });
  const right = hashVisitRecommendationsRequest({
    items: [{ wikiItemId: 'wiki-one', id: 'one' }],
    dossierId: 'dossier-1',
  });
  assert.equal(left, right);
});

test('agent2 NocoDB adapter uses exactly one conditional update attempt', async () => {
  const initialItems = snapshot().items;
  let row = {
    Id: 7,
    dossier_id: 'dossier-1',
    items_json: JSON.stringify(initialItems),
    request_hash: hashVisitRecommendationsRequest({
      dossierId: 'dossier-1',
      items: initialItems,
    }),
    app_sync_revision: revision,
    last_write_id: revision,
    updated_at: '2026-09-10T08:00:00.000Z',
  };
  const calls = [];
  const request = async (call) => {
    calls.push(clone(call));
    if (call.method === 'GET') return { list: [clone(row)] };
    if (call.method === 'PATCH') {
      row = { ...row, ...clone(call.body) };
      return { count: 1 };
    }
    throw new Error(`Unexpected ${call.method}`);
  };
  const store = createNocodbVisitRecommendationsSnapshotStore({
    baseId: 'base_one',
    tableId: 'table_one',
    request,
  });
  const next = {
    dossierId: 'dossier-1',
    revision: writeOne,
    lastWriteId: writeOne,
    requestHash: hashVisitRecommendationsRequest({
      dossierId: 'dossier-1',
      items: [],
    }),
    items: [],
    updatedAt: '2026-09-10T09:00:00.000Z',
  };

  const result = await store.compareAndSwap({
    dossierId: 'dossier-1',
    expectedRevision: revision,
    next,
  });

  assert.equal(result.status, 'applied');
  assert.equal(calls.filter((call) => call.method === 'PATCH').length, 1);
  assert.equal(calls.filter((call) => call.method === 'GET').length, 2);
});

test('agent2 NocoDB adapter never retries a failed write', async () => {
  const initialItems = snapshot().items;
  const row = {
    Id: 7,
    dossier_id: 'dossier-1',
    items_json: JSON.stringify(initialItems),
    request_hash: hashVisitRecommendationsRequest({
      dossierId: 'dossier-1',
      items: initialItems,
    }),
    app_sync_revision: revision,
    last_write_id: revision,
    updated_at: '2026-09-10T08:00:00.000Z',
  };
  let patchCalls = 0;
  const store = createNocodbVisitRecommendationsSnapshotStore({
    baseId: 'base_one',
    tableId: 'table_one',
    request: async ({ method }) => {
      if (method === 'GET') return { list: [clone(row)] };
      if (method === 'PATCH') {
        patchCalls += 1;
        throw new Error('network response lost');
      }
      throw new Error(`Unexpected ${method}`);
    },
  });

  await assert.rejects(
    store.compareAndSwap({
      dossierId: 'dossier-1',
      expectedRevision: revision,
      next: {
        ...snapshot([]),
        revision: writeOne,
        lastWriteId: writeOne,
        requestHash: hashVisitRecommendationsRequest({
          dossierId: 'dossier-1',
          items: [],
        }),
      },
    }),
    /network response lost/,
  );
  assert.equal(patchCalls, 1);
});

test('agent2 NocoDB read rejects a row outside the requested dossier', async () => {
  const wrongItems = [storedItem('wrong')];
  const store = createNocodbVisitRecommendationsSnapshotStore({
    baseId: 'base_one',
    tableId: 'table_one',
    request: async () => ({
      list: [{
        Id: 9,
        dossier_id: 'another-dossier',
        items_json: JSON.stringify(wrongItems),
        request_hash: hashVisitRecommendationsRequest({
          dossierId: 'another-dossier',
          items: wrongItems,
        }),
        app_sync_revision: revision,
        last_write_id: revision,
        updated_at: '2026-09-10T08:00:00.000Z',
      }],
    }),
  });

  await assert.rejects(
    store.read('dossier-1'),
    errorCode('VISIT_RECOMMENDATIONS_SNAPSHOT_SCOPE_MISMATCH', 503),
  );
});

test('agent2 NocoDB read rejects content inconsistent with its stored hash', async () => {
  const expectedItems = [storedItem('expected')];
  const store = createNocodbVisitRecommendationsSnapshotStore({
    baseId: 'base_one',
    tableId: 'table_one',
    request: async () => ({
      list: [{
        Id: 10,
        dossier_id: 'dossier-1',
        items_json: JSON.stringify([storedItem('tampered')]),
        request_hash: hashVisitRecommendationsRequest({
          dossierId: 'dossier-1',
          items: expectedItems,
        }),
        app_sync_revision: revision,
        last_write_id: revision,
        updated_at: '2026-09-10T08:00:00.000Z',
      }],
    }),
  });

  await assert.rejects(
    store.read('dossier-1'),
    errorCode('VISIT_RECOMMENDATIONS_SNAPSHOT_CORRUPT', 503),
  );
});
