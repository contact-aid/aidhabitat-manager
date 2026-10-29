import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {VisitStore,VisitProcessor} from './visitAssistant.mjs';
import {VisitQueue} from './visitQueue.mjs';
async function fixture(t,overrides={}) {
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'visit-queue-'));t.after(()=>fs.rm(dir,{recursive:true,force:true}));
 const store=new VisitStore(dir);const job={id:'c'.repeat(32),dossierId:'fiction',status:'transcribing',context:{handwritten:[]},chunks:[{duration:60},{duration:20}],chunkCount:2,transcript:[{index:0,startSeconds:0,text:'Already paid'}],result:null};
 await store.write(job);await fs.writeFile(path.join(store.dir(job.dossierId,job.id),'1.m4a'),'fiction');
 const calls=[];
 const processor=new VisitProcessor({store,retryDelayMs:0,provider:{transcribe:async()=>{calls.push('audio');return 'Last segment';},extractFacts:async()=>{calls.push('facts');return {facts:[],warnings:[]};},draft:async()=>{calls.push('draft');return {sections:{'Accessibilité-Notes':'Ajout'},warnings:[]};},...overrides},applyResult:async()=>{calls.push('apply');}});
 return {store,processor,job,calls};
}
test('server resumes without an iPad and never retranscribes acknowledged segments',async t=>{
 const f=await fixture(t);const queue=new VisitQueue({...f,retryDelayMs:0});t.after(()=>queue.close());
 const first=queue.enqueue(f.job.dossierId,f.job.id);assert.equal(first,queue.enqueue(f.job.dossierId,f.job.id));await first;
 assert.equal((await f.store.read(f.job.dossierId,f.job.id)).status,'complete');assert.deepEqual(f.calls,['audio','facts','draft','apply']);
 const afterRestart=new VisitQueue({...f});await afterRestart.resume();assert.equal(afterRestart.running.size,0);afterRestart.close();
});
test('two failed paid attempts stop; subsequent polls incur no new provider calls',async t=>{
 let calls=0;const f=await fixture(t,{transcribe:async()=>{calls++;throw Object.assign(new Error('Provider unavailable'),{statusCode:502});}});
 for(let i=0;i<4;i++)await assert.rejects(f.processor.step(f.job.dossierId,f.job.id));
 assert.equal(calls,2);const job=await f.store.read(f.job.dossierId,f.job.id);assert.equal(job.status,'failed');assert.equal(job.transcript.length,1);
});
test('failed note application reuses the paid draft checkpoint',async t=>{
 const f=await fixture(t);let attempts=0;f.processor.applyResult=async()=>{if(!attempts++)throw Object.assign(new Error('Concurrent edit'),{statusCode:409});};
 await f.processor.step(f.job.dossierId,f.job.id);await f.processor.step(f.job.dossierId,f.job.id);await f.processor.step(f.job.dossierId,f.job.id);
 await assert.rejects(f.processor.step(f.job.dossierId,f.job.id));await f.processor.step(f.job.dossierId,f.job.id);
 assert.equal(f.calls.filter(c=>c==='draft').length,1);assert.equal((await f.store.read(f.job.dossierId,f.job.id)).status,'complete');
});
