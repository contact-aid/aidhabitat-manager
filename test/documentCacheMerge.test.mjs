import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

// Exercise the actual cache merge with instrumented browser-storage adapters.
const source = readFileSync(new URL('../services/dataService.ts', import.meta.url), 'utf8');
const start = source.indexOf('const mergeRemoteDocumentsIntoLocalCache =');
const end = source.indexOf('\nconst fetchRemoteDocuments =', start);
const compiled = ts.transpile(source.slice(start, end) + '\nglobalThis.merge = mergeRemoteDocumentsIntoLocalCache;', { target: ts.ScriptTarget.ES2022 });
const setup = (initial, queue = []) => {
  let records = initial;
  let reads = 0;
  let writes = 0;
  const context = vm.createContext({
    readLocalDocumentQueue: () => queue,
    readLocalDocumentRecords: () => { reads++; return records; },
    writeLocalDocumentRecords: (next) => { writes++; records = next; },
  });
  vm.runInContext(compiled, context);
  return { merge: context.merge, state: () => ({ records, reads, writes }) };
};

test('merging 500 remote documents reads and writes the metadata cache once', async () => {
  const cache = setup([]);
  await cache.merge(Array.from({ length: 500 }, (_, i) => ({ id: String(i), title: `Photo ${i}`, updatedAt: '2026-10-26' })));
  assert.equal(cache.state().records.length, 500);
  assert.equal(cache.state().reads, 1);
  assert.equal(cache.state().writes, 1);
  await cache.merge(Array.from({ length: 500 }, (_, i) => ({ id: String(i), title: `Photo ${i}`, updatedAt: '2026-10-26' })));
  assert.equal(cache.state().writes, 1, 'unchanged polling must not rewrite storage');
});

test('remote refresh preserves pending renames, deletions and unrelated documents', async () => {
  const initial = [
    { id: 'local-1', remoteId: 'remote-1', title: 'Titre saisi', syncStatus: 'pending' },
    { id: 'local-2', remoteId: 'remote-2', title: 'Supprimé', syncStatus: 'pending' },
    { id: 'other', title: 'Autre dossier' },
  ];
  const cache = setup(initial, [{ documentId: 'local-1', type: 'update' }, { documentId: 'local-2', type: 'delete' }]);
  await cache.merge([{ id: 'remote-1', title: 'Ancien titre' }, { id: 'remote-2', title: 'Ancien document' }]);
  assert.equal(cache.state().writes, 0);
  assert.deepEqual(cache.state().records, initial);
});

test('remote updates retain the local id used by the blob cache', async () => {
  const cache = setup([{ id: 'local', remoteId: 'remote', title: 'Avant' }]);
  await cache.merge([{ id: 'remote', title: 'Après', updatedAt: '2026-10-26' }]);
  assert.equal(cache.state().records.length, 1);
  assert.equal(cache.state().records[0].id, 'local');
  assert.equal(cache.state().records[0].title, 'Après');
});
