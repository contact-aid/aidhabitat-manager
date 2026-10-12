import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { planCarsat, applyCarsat } from './prepare-carsat.mjs';
import { withLocalPrincipalRetirementFunds } from '../server/local-preview/principalRetirementFunds.mjs';
const fixture = JSON.parse(await readFile(new URL('./fixtures/carsat/principal-funds.synthetic.json',import.meta.url)));
test('plan is read-only; apply adds one name and preserves all existing values', () => {
 const before=structuredClone(fixture);const plan=planCarsat(fixture);
 assert.equal(plan.action,'create');assert.deepEqual(fixture,before);
 const first=applyCarsat(fixture,plan);assert.equal(first.created,true);
 assert.deepEqual(first.fixture.records.slice(0,-1),before.records);
 assert.deepEqual(first.fixture.records.at(-1),{id:'103',fields:{nom:'CARSAT'}});
 assert.deepEqual(applyCarsat(first.fixture,plan),{fixture:first.fixture,created:false,id:'103'});
 assert.equal(planCarsat(first.fixture).action,'noop');
});
test('existing spelling variants retain real ID and metadata',()=>{
 const f=structuredClone(fixture);f.records.push({id:'110',fields:{nom:'  carsat  ',phone:'preserve'}});
 assert.equal(planCarsat(f).action,'noop');assert.equal(applyCarsat(f,planCarsat(f)).fixture,f);
});
test('duplicates, regional ambiguity and invalid source fail closed',()=>{
 for(const extra of [[{id:'110',fields:{nom:'CARSAT Bretagne'}}],[{id:'110',fields:{nom:'CARSAT'}},{id:'111',fields:{nom:'carsat'}}]])assert.throws(()=>planCarsat({...fixture,records:[...fixture.records,...extra]}),/manual review/);
 assert.throws(()=>planCarsat({...fixture,environment:'production'}),/synthetic/);
});
test('stale or tampered plan is rejected without mutation',()=>{
 const f=structuredClone(fixture);const plan=planCarsat(f);f.records[0].fields.nom='changed';
 assert.throws(()=>applyCarsat(f,plan),/Reference changed/);
 assert.throws(()=>applyCarsat(f,{...plan,fields:{nom:'OTHER'}}),/Invalid/);
 assert.equal(f.records.length,2);
});
test('preview is additive, idempotent and never replaces an existing real CARSAT',()=>{
 const payload={success:true,data:{funds:[{id:'101',name:'MSA'}]}};
 const preview=withLocalPrincipalRetirementFunds(payload);
 assert.equal(payload.data.funds.length,1);assert.equal(preview.data.funds.length,2);
 assert.deepEqual(withLocalPrincipalRetirementFunds(preview),preview);
 const real={success:true,data:{funds:[{id:'987',name:' carsat ',phone:'preserve'}]}};
 assert.deepEqual(withLocalPrincipalRetirementFunds(real),real);
 assert.equal(withLocalPrincipalRetirementFunds({success:false}).success,false);
});
test('CLI applies twice to a disk fixture and refuses an active lock',async()=>{
 const dir=await mkdtemp(join(tmpdir(),'carsat-synthetic-'));
 try {
  const file=join(dir,'fixture.json'),planFile=join(dir,'plan.json');
  await writeFile(file,JSON.stringify(fixture));await writeFile(planFile,JSON.stringify(planCarsat(fixture)));
  const run=()=>spawnSync(process.execPath,['tools/prepare-carsat.mjs','apply','--fixture',file,'--plan',planFile],{encoding:'utf8'});
  assert.equal(run().status,0);assert.equal(JSON.parse(run().stdout).created,false);
  assert.equal(JSON.parse(await readFile(file,'utf8')).records.length,3);
  await writeFile(`${file}.carsat.lock`,'');assert.notEqual(run().status,0);
 } finally {await rm(dir,{recursive:true,force:true});}
});
