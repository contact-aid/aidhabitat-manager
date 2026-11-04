import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import path from 'node:path';import os from 'node:os';
import {transcribeVisitParts,readDiarizedResponse} from './openaiVisitAudio.mjs';import {cleanVisitTranscript} from './openaiVisitCleanup.mjs';
test('long recordings are bounded, carry reference voices across parts, and reuse paid checkpoints',async t=>{
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'long-visit-'));t.after(()=>fs.rm(directory,{force:true,recursive:true}));
 let uploads=0;const options={directory,job:{id:'synthetic',dossierId:'synthetic',chunks:[{duration:600}]},bytes:Buffer.from('synthetic'),model:'gpt-4o-transcribe-diarize',apiKey:'synthetic',
 sliceAudio:async({output})=>{const b=Buffer.from('synthetic clip');await fs.writeFile(output,b);return b;},
 fetchImpl:async(url,request)=>{
   const index=uploads++;const names=request.body.getAll('known_speaker_names[]');
   if(index===0){assert.deepEqual(names,[]);return Response.json({segments:[{speaker:'A',start:0,end:5,text:'Bonjour.'},{speaker:'B',start:7,end:12,text:'Je marche avec une canne.'}]});}
   assert.deepEqual(names,['voice_1','voice_2']);assert.equal(request.body.getAll('known_speaker_references[]').length,2);
   return Response.json({segments:[{speaker:'voice_2',start:0,end:5,text:'Je ne suis pas tombé.'}]});
 }};
 const result=await transcribeVisitParts(options);assert.equal(uploads,2);
 assert.equal(result.segments[1].speaker,result.segments[2].speaker);assert.equal(result.segments[2].start,300);
 assert.deepEqual(await transcribeVisitParts(options),result);assert.equal(uploads,2);
});
test('cleanup splits a long conversation and reuses all successful batches after one failure',async t=>{
 const directory=await fs.mkdtemp(path.join(os.tmpdir(),'long-clean-'));t.after(()=>fs.rm(directory,{force:true,recursive:true}));
 const segments=Array.from({length:450},(_,i)=>({text:`La porte mesure ${i+10} cm.`,speaker:'voice_1'}));
 const counts=new Map();let fail=true;
 const complete=async messages=>{
   const segments=JSON.parse(messages[1].content).segments;const id=segments[0].id;counts.set(id,(counts.get(id)||0)+1);
   if(id===200&&fail)throw Error('synthetic interruption');
   return JSON.stringify({turns:segments.map(s=>({id:s.id,cleanText:s.text})),speakers:[{id:'voice_1',role:'participant'}]});
 };
 await assert.rejects(cleanVisitTranscript({segments,directory,complete}),/interruption/);
 fail=false;const result=await cleanVisitTranscript({segments,directory,complete});
 assert.equal(result.turns.length,450);assert.equal(counts.get(0),1);assert.equal(counts.get(200),2);assert.equal(counts.get(400),1);
});
test('diarized streaming accepts CRLF frames and finishes on the done event',async()=>{
 const frames=[
   'event: transcript.text.segment\r\ndata: '+JSON.stringify({type:'transcript.text.segment',id:'s0',start:0,end:3,speaker:'A',text:'La porte mesure 78 cm.'})+'\r\n\r\n',
   'data: '+JSON.stringify({type:'transcript.text.done',text:'La porte mesure 78 cm.'})+'\r\n\r\n',
 ];
 const result=await readDiarizedResponse(new Response(frames.join(''),{headers:{'content-type':'text/event-stream'}}));
 assert.equal(result.segments.length,1);assert.equal(result.segments[0].speaker,'A');
 await assert.rejects(readDiarizedResponse(new Response(frames[0],{headers:{'content-type':'text/event-stream'}})),/incomplet/);
});
