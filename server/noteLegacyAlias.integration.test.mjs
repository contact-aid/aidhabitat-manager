import test from 'node:test';
import assert from 'node:assert/strict';
import {createNocodbStoreAdapter} from './mobileSyncStore.mjs';
const revision='11111111-1111-4111-8111-111111111111', writeId='22222222-2222-4222-8222-222222222222';
const address={patientId:'patient-98',dossierId:'dossier-98',scopeType:'dossier_detail',scopeId:'dossier-98',tabKey:'Contexte de vie-Autonomie',pageNumber:0,subTabKey:'',expectedRevision:revision,writeId,drawingJson:'{"text":"local edit"}'};
function harness({remoteRevision=revision,duplicate=false}={}) {
 const record={id:'98',fields:{uuid_source:'note-98',beneficiaire_id:'patient-98',dossier_id:'dossier-98',scope_type:'dossier_detail',scope_id:'patient-98',tab_key:address.tabKey,sub_tab_key:'',page_number:0,app_sync_revision:remoteRevision}};
 const patches=[];
 const io={
  callNocoTool:async()=>({fields:[]}),
  queryAll:async(_table,{where})=>{
   if(where.includes('(uuid_source,')) return [record];
   if(where.includes('(scope_id,eq,"dossier-98")')) return [];
   if(where.includes('(scope_id,eq,"patient-98")')) return duplicate?[record,record]:[record];
   return [];
  },
  requestConditionalNocodbRest:async request=>{patches.push(request);Object.assign(record.fields,request.body);},
  createRecord:async()=>{throw Error('must never create a missing update');},
  updateRecord:async()=>{},deleteRecord:async()=>{throw Error('must not delete');}
 };
 return {adapter:createNocodbStoreAdapter({absoluteUrl:p=>p,notePagesTableId:'notes',io,preferLocal:true}),patches};
}
test('dossier alias retries legacy page with guarded revision and same write id',async()=>{
 const h=harness();const saved=await h.adapter.upsertNotePage(address);
 assert.equal(saved.revision,writeId);assert.equal(saved.scopeId,'patient-98');
 assert.equal(h.patches.length,1);assert.equal(h.patches[0].body.scope_id,'patient-98');
 assert.match(decodeURIComponent(h.patches[0].path),new RegExp(revision));
});
test('changed remote revision never overwrites another writer even in preferLocal mode',async()=>{
 const h=harness({remoteRevision:'33333333-3333-4333-8333-333333333333'});
 await assert.rejects(h.adapter.upsertNotePage(address),e=>e.code==='NOTE_PAGE_REVISION_CONFLICT');assert.equal(h.patches.length,0);
});
test('ambiguous legacy pages remain blocked without writes',async()=>{
 const h=harness({duplicate:true});await assert.rejects(h.adapter.upsertNotePage(address),e=>e.code==='NOTE_PAGE_RECORD_MISSING');assert.equal(h.patches.length,0);
});
