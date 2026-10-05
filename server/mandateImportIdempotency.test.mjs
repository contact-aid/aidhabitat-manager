import test from 'node:test';
import assert from 'node:assert/strict';
import { createNocodbStoreAdapter } from './mobileSyncStore.mjs';
function fixture() {
  const rows = [];
  const chunks = [];
  let writes = 0;
  const matches = (r,w) => [...w.matchAll(/\((\w+),eq,("(?:[^"\\]|\\.)*")\)/g)]
    .every(([,key,raw])=>String(r.fields[key]) === JSON.parse(raw));
  const io = {
    queryAll: async (table, {where}) => structuredClone((table === 'fiction-chunks' ? chunks : rows).filter(r=>matches(r,where))),
    createRecord: async (_, fields) => {
      await new Promise(resolve=>setTimeout(resolve,5));
      const row={id:String(rows.length+1),fields:structuredClone(fields)};rows.push(row);writes++;return structuredClone(row);
    },
    updateRecord: async ()=>{throw new Error('Immutable import must not update');},
    deleteRecord: async ()=>{throw new Error('No deletion');},
    callNocoTool: async ()=>{throw new Error('No real IO');},
    requestConditionalNocodbRest: async ()=>{throw new Error('No real IO');},
  };
  const config={absoluteUrl:p=>`https://synthetic.invalid${p}`,documentsTableId:'fiction-docs',documentChunksTableId:'fiction-chunks',io};
  const one=createNocodbStoreAdapter(config),two=createNocodbStoreAdapter(config);
  const payload={patientId:'patient-fiction',dossierId:'dossier-fiction',documentLocalId:'doc_mandat_dossier-fiction_account1',title:'Mandat fictif',fileName:'fictif.pdf',mimeType:'application/pdf',tags:['Mandat'],contentBase64:Buffer.from('%PDF-fictif').toString('base64')};
  return {rows,chunks,one,two,payload,writes:()=>writes};
}
test('two device imports and a lost reply preserve one record and stable document URL',async()=>{
  const f=fixture();
  const [a,b]=await Promise.all([f.one.upsertDocument(f.payload),f.two.upsertDocument(f.payload)]);
  const replay=await f.two.upsertDocument(f.payload);
  assert.equal(f.rows.length,1);assert.equal(f.writes(),1);
  assert.equal(a.id,b.id);assert.equal(replay.id,a.id);
});
test('annotated or differing existing content conflicts without replacing either copy',async()=>{
  const f=fixture();await f.one.upsertDocument(f.payload);
  f.rows[0].fields.contenu_base64=Buffer.from('%PDF-annotated').toString('base64');
  const before=structuredClone(f.rows);
  await assert.rejects(f.two.upsertDocument(f.payload),e=>e.status===409&&e.code==='DOCUMENT_IMPORT_ALREADY_EXISTS');
  assert.deepEqual(f.rows,before);assert.equal(f.writes(),1);
});
test('account identities are distinct; same ID cannot cross dossier',async()=>{
  const f=fixture();await f.one.upsertDocument(f.payload);
  await f.two.upsertDocument({...f.payload,documentLocalId:'doc_mandat_dossier-fiction_account2'});
  assert.equal(f.rows.length,2);
  await assert.rejects(f.two.upsertDocument({...f.payload,dossierId:'other-dossier'}),e=>e.status===403);
});

test('lost reply for chunked mandate compares complete ordered contents without writes',async()=>{
  const f=fixture();const saved=await f.one.upsertDocument(f.payload);
  f.rows[0].fields.contenu_base64='';
  const value=f.payload.contentBase64;
  f.chunks.push({id:'c2',fields:{document_uuid_source:saved.id,chunk_index:1,chunk_base64:value.slice(5)}},
    {id:'c1',fields:{document_uuid_source:saved.id,chunk_index:0,chunk_base64:value.slice(0,5)}});
  const replay=await f.two.upsertDocument(f.payload);
  assert.equal(replay.id,saved.id);assert.equal(f.writes(),1);
  f.chunks[0].fields.chunk_index=3;
  await assert.rejects(f.two.upsertDocument(f.payload),e=>e.code==='DOCUMENT_IMPORT_ALREADY_EXISTS');
});
