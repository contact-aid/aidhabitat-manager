import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createVisitPhotoOrderStore } from './visitPhotoOrderStore.mjs';
const categoryTag = 'Visite - Accessibilité';
const docs = ['a','b','c'].map(id => ({id, clientDocumentId:`doc_${id}`, tags:[categoryTag], createdAt:'2026-10-01'}));
const payload = (ids, mutationId, modifiedAt='2026-10-22T10:00:00Z') => ({ categoryTag, orderedDocumentIds:ids, mutationId, modifiedAt });
async function fixture(action) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(),'shared-photo-order-'));
  try { await action(createVisitPhotoOrderStore(directory), directory); }
  finally { await fs.rm(directory,{recursive:true,force:true}); }
}
const ids = documents => documents.slice().sort((a,b) => a.categoryOrder-b.categoryOrder).map(d=>d.id);
test('two browsers share the same saved order across a server restart and metadata changes', () => fixture(async (store, directory) => {
  await store.save('patient', payload(['doc_c','doc_a','doc_b'],'drag-1'));
  assert.deepEqual(ids(await store.apply('patient',docs)),['c','a','b']);
  const restarted = createVisitPhotoOrderStore(directory);
  assert.deepEqual(ids(await restarted.apply('patient', docs.toReversed().map(d=>({...d,updatedAt:'2099-01-01'})))),['c','a','b']);
  assert((await restarted.apply('patient',docs)).every(d=>d.photoOrderShared));
  assert((await restarted.apply('another-patient',docs)).every(d=>!d.photoOrderShared));
}));
test('a stale browser initialization and late offline retries cannot replace a newer explicit drag', () => fixture(async store => {
  await store.save('patient', {...payload(['a','b','c'],'init'),initializeOnly:true});
  await store.save('patient', payload(['c','b','a'],'newer','2026-10-22T09:00:00Z'));
  await store.save('patient', {...payload(['a','c','b'],'stale-init','2026-10-22T14:00:00Z'),initializeOnly:true});
  await store.save('patient', payload(['b','a','c'],'old-retry','2026-10-22T08:00:00Z'));
  assert.deepEqual(ids(await store.apply('patient',docs)),['c','b','a']);
}));
test('new photos append once and do not move when later photos arrive', () => fixture(async store => {
  await store.save('patient', payload(['a'],'drag'));
  assert.deepEqual(ids(await store.apply('patient',docs.slice(0,2))),['a','b']);
  assert.deepEqual(ids(await store.apply('patient',docs)),['a','b','c']);
  await store.save('patient', payload(['a'],'drag')); // replay must preserve appended photos
  assert.deepEqual(ids(await store.apply('patient',docs.toReversed())),['a','b','c']);
}));
test('simultaneous initializations keep the first published order', () => fixture(async store => {
  await Promise.all([
    store.save('patient',{...payload(['c','a','b'],'first'),initializeOnly:true}),
    store.save('patient',{...payload(['b','a','c'],'second'),initializeOnly:true}),
  ]);
  assert.deepEqual(ids(await store.apply('patient',docs)),['c','a','b']);
}));
test('categories remain independent and malformed data is rejected', () => fixture(async store => {
  await store.save('patient', payload(['c','a','b'],'access'));
  await store.save('patient', {...payload(['b','c','a'],'housing'),categoryTag:'Visite - Logement'});
  assert.deepEqual(ids(await store.apply('patient',docs)),['c','a','b']);
  await assert.rejects(store.save('patient',{...payload(['a'],'bad'),categoryTag:'__proto__'}),/invalide/);
}));
