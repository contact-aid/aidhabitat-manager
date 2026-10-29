import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizeHousingAccessBaseline} from './housingNullableAccess.mjs';
import {createGuardedMutation,SYNC_REVISION_FIELD} from './guardedMutation.mjs';
const original='2026-10-29T08:00:00.123456Z', newer='2026-10-29T08:01:00.123456Z';
const revision='11111111-1111-4111-8111-111111111111', writeId='22222222-2222-4222-8222-222222222222';
function setup({time=original,baseline='false',desired='true',race=false}={}) {
  let row={acces_facile_rue:null,garage:'false',rdc:'false',chauffage:'false',updatedAt:time,[SYNC_REVISION_FIELD]:revision};
  const writes=[];
  const mutate=createGuardedMutation({readRecord:async()=>structuredClone(row),writer:async input=>{
    writes.push(input);
    if(race){row.updatedAt=newer;row[SYNC_REVISION_FIELD]='33333333-3333-4333-8333-333333333333';return {reason:'revision_changed'};}
    return {status:'applied'};
  }});
  const args={tableId:'housing',recordId:1,writeId,
    fields:{acces_facile_rue:desired,garage:'true',rdc:'true',chauffage:'true'},
    baseFields:{acces_facile_rue:baseline,garage:'false',rdc:'false',chauffage:'false'},
    normalizeBaseline:(base,observed)=>normalizeHousingAccessBaseline({baseline:base,observed,expectedUpdatedAt:original,observedUpdatedAt:observed.updatedAt})};
  return {mutate,args,writes};
}
for(const desired of ['true','false'])test(`first answer ${desired} accepts the complete levels/equipment/exterior patch`,async()=>{
  const {mutate,args,writes}=setup({desired,baseline:null});await mutate(args);
  assert.deepEqual(writes[0].fields,args.fields);
});
test('legacy projected false repairs only the baseline, retaining desired No and all other fields',async()=>{
  const {mutate,args,writes}=setup({desired:'false'});await mutate(args);
  assert.deepEqual(writes[0].fields,args.fields);assert.equal(args.baseFields.acces_facile_rue,'false');
});
test('a newer web edit or clear is never overwritten by legacy baseline recovery',async()=>{
  const {mutate,args,writes}=setup({time:newer});
  await assert.rejects(mutate(args),e=>e.code==='SYNC_FIELD_CONFLICT');assert.equal(writes.length,0);
});
test('a web edit racing the guarded write is rechecked against the ORIGINAL baseline',async()=>{
  const {mutate,args,writes}=setup({race:true});
  await assert.rejects(mutate(args),e=>e.code==='SYNC_FIELD_CONFLICT');assert.equal(writes.length,1);
});
test('missing versions, explicit false and sub-millisecond version changes never normalize',()=>{
  const baseline={acces_facile_rue:'false'};
  for(const options of [{expectedUpdatedAt:null},{observedUpdatedAt:null},{observedUpdatedAt:'2026-10-29T08:00:00.123457Z'},{observed:{acces_facile_rue:'false'}},{observed:{}}]) {
    assert.deepEqual(normalizeHousingAccessBaseline({baseline,observed:{acces_facile_rue:null},expectedUpdatedAt:original,observedUpdatedAt:original,...options}),baseline);
  }
});
