import assert from 'node:assert/strict';
import test from 'node:test';

import {
  WikiPersistenceError,
  deleteWikiRecord,
  persistWikiRecord,
} from './wikiLibraryPersistence.mjs';

const itemId = 'wiki_create_local_draft_synthetic';
const fields = (title = 'Barre de maintien') => ({
  uuid_source: itemId,
  titre: title,
  photos: '',
  photo_base64: 'data:image/png;base64,c3ludGhldGlj',
  contenu: JSON.stringify({ description: title, category: 'Autre', tags: ['WC'] }),
  wiki_tags_id: 42,
});

function database(initial = []) {
  let rows = structuredClone(initial);
  let creates = 0;
  let updates = 0;
  let deletes = 0;
  let failBeforeWrite = false;
  let loseAfterWrite = false;
  return {
    read: async () => structuredClone(rows),
    create: async (payload) => {
      creates += 1;
      if (failBeforeWrite) throw new Error('NocoDB unavailable');
      rows.push({ id: rows.length + 1, fields: structuredClone(payload) });
      if (loseAfterWrite) throw new Error('response lost');
    },
    update: async (record, payload) => {
      updates += 1;
      if (failBeforeWrite) throw new Error('NocoDB unavailable');
      record = rows.find((row) => row.id === record.id);
      record.fields = structuredClone(payload);
      if (loseAfterWrite) throw new Error('response lost');
    },
    delete: async (record) => {
      deletes += 1;
      if (failBeforeWrite) throw new Error('NocoDB unavailable');
      rows = rows.filter((row) => row.id !== record.id);
      if (loseAfterWrite) throw new Error('response lost');
    },
    fail: () => { failBeforeWrite = true; },
    lose: () => { loseAfterWrite = true; },
    rows: () => structuredClone(rows),
    counts: () => ({ creates, updates, deletes }),
  };
}

for (const operation of ['create', 'update']) {
  test(`panne NocoDB sur ${operation} ne confirme rien`, async () => {
    const db = database(operation === 'update'
      ? [{ id: 7, fields: fields('Avant') }]
      : []);
    db.fail();
    await assert.rejects(
      persistWikiRecord({
        operation,
        itemId,
        fields: fields('Après'),
        readRecords: db.read,
        createRecord: db.create,
        updateRecord: db.update,
      }),
      (error) => error instanceof WikiPersistenceError
        && error.code === 'WIKI_PERSISTENCE_UNCONFIRMED'
        && error.statusCode === 503,
    );
    assert.equal(db.rows().length, operation === 'update' ? 1 : 0);
  });
}

test('panne NocoDB sur DELETE ne confirme pas la suppression', async () => {
  const db = database([{ id: 7, fields: fields() }]);
  db.fail();
  await assert.rejects(
    deleteWikiRecord({ itemId, readRecords: db.read, deleteRecord: db.delete }),
    (error) => error.code === 'WIKI_DELETE_UNCONFIRMED',
  );
  assert.equal(db.rows().length, 1);
});

test('réponse perdue après POST est confirmée puis rejouée sans doublon', async () => {
  const db = database();
  db.lose();
  const input = {
    operation: 'create',
    itemId,
    fields: fields(),
    readRecords: db.read,
    createRecord: db.create,
    updateRecord: db.update,
  };
  const first = await persistWikiRecord(input);
  const replay = await persistWikiRecord(input);
  assert.equal(first.record.fields.uuid_source, itemId);
  assert.equal(replay.replay, true);
  assert.equal(db.rows().length, 1);
  assert.deepEqual(db.counts(), { creates: 1, updates: 0, deletes: 0 });
});

test('réponse perdue après PUT est confirmée par le contenu relu', async () => {
  const db = database([{ id: 7, fields: fields('Avant') }]);
  db.lose();
  const result = await persistWikiRecord({
    operation: 'update',
    itemId,
    fields: fields('Après'),
    readRecords: db.read,
    createRecord: db.create,
    updateRecord: db.update,
  });
  assert.equal(result.record.fields.titre, 'Après');
  assert.equal(db.counts().updates, 1);
});

test('réponse perdue après DELETE est confirmée par absence', async () => {
  const db = database([{ id: 7, fields: fields() }]);
  db.lose();
  const result = await deleteWikiRecord({
    itemId,
    readRecords: db.read,
    deleteRecord: db.delete,
  });
  assert.equal(result.replay, false);
  assert.equal(db.rows().length, 0);
  assert.equal(db.counts().deletes, 1);
});

test('un brouillon modifié après réponse perdue garde une seule identité', async () => {
  const db = database([{ id: 7, fields: fields('Original') }]);
  const result = await persistWikiRecord({
    operation: 'create',
    itemId,
    fields: fields('Modifié localement'),
    readRecords: db.read,
    createRecord: db.create,
    updateRecord: db.update,
  });
  assert.equal(result.record.fields.titre, 'Modifié localement');
  assert.equal(db.rows().length, 1);
  assert.deepEqual(db.counts(), { creates: 0, updates: 1, deletes: 0 });
});

test('une modification concurrente après PUT empêche un faux succès', async () => {
  let rows = [{ id: 7, fields: fields('Avant') }];
  let reads = 0;
  await assert.rejects(
    persistWikiRecord({
      operation: 'update',
      itemId,
      fields: fields('Notre modification'),
      readRecords: async () => {
        reads += 1;
        if (reads === 2) rows[0].fields = fields('Modification concurrente');
        return structuredClone(rows);
      },
      createRecord: async () => assert.fail('unexpected create'),
      updateRecord: async (_record, payload) => { rows[0].fields = structuredClone(payload); },
    }),
    (error) => error.code === 'WIKI_PERSISTENCE_UNCONFIRMED',
  );
  assert.equal(rows[0].fields.titre, 'Modification concurrente');
});
