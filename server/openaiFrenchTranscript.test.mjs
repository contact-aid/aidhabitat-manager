import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs/promises';import os from 'node:os';import path from 'node:path';
import {transcribeFrenchChunks,arrangeFrenchTranscript} from './openaiFrenchTranscript.mjs';
const temp=async t=>{const d=await fs.mkdtemp(path.join(os.tmpdir(),'fr-transcript-'));t.after(()=>fs.rm(d,{force:true,recursive:true}));return d;};
test('French text uses the current transcription model and retries reuse authoritative words',async t=>{
 const directory=await temp(t);await fs.writeFile(path.join(directory,'0.m4a'),'synthetic');let calls=0;
 const options={directory,job:{chunks:[{duration:60}]},apiKey:'synthetic',fetchImpl:async(url,request)=>{
  calls++;assert.equal(request.body.get('model'),'gpt-transcribe');assert.deepEqual(request.body.getAll('languages[]'),['fr']);assert.equal(request.body.get('language'),null);
  return Response.json({text:'La porte mesure 87 cm.',languages:[{code:'fr'}]});
 }};
 assert.equal((await transcribeFrenchChunks(options))[0].text,'La porte mesure 87 cm.');await transcribeFrenchChunks(options);assert.equal(calls,1);
});
test('translated diarization words cannot replace French sources or invent a fifth person',async t=>{
 const directory=await temp(t),text='Je ne suis pas tombé. Le seuil mesure 12 cm.';let cleanedInput;
 const result=await arrangeFrenchTranscript({directory,chunks:[{index:0,startSeconds:0,duration:60,text}],
  voiceSegments:[{speaker:'voice_1',start:0,end:5,text:'Yeah. You cannot have a rabbit.'}],referenceVoices:['voice_1'],
  complete:async(messages,options)=>{
   if(options.task==='transcript_dialogue')return JSON.stringify({chunks:[{index:0,turns:[{speaker:'invented_person',text:'Yeah.'}]}],speakers:[]});
   const data=JSON.parse(messages[1].content);cleanedInput=data;
   return JSON.stringify({turns:data.segments.map(s=>({id:s.id,cleanText:'Le seuil est adapté.'})),speakers:[{id:'unidentified',role:'unknown'}]});
  }});
 assert.equal(result.formatted[0].turns.length,1);assert.equal(result.formatted[0].turns[0].text,text);assert.equal(result.formatted[0].turns[0].speaker,null);
 assert.equal(result.cleanTexts.get(0),text);assert.ok(!JSON.stringify(cleanedInput).includes('rabbit'));
});
test('valid French paragraphs keep source words while voices remain a proposal',async t=>{
 const directory=await temp(t);const parts=['Comment accédez-vous à la douche ?','Je ne peux pas franchir le seuil de 12 cm.'];
 const result=await arrangeFrenchTranscript({directory,chunks:[{index:0,startSeconds:0,duration:60,text:parts.join(' ')}],voiceSegments:[],referenceVoices:['voice_1','voice_2'],
 complete:async(messages,options)=>{
  if(options.task==='transcript_dialogue')return JSON.stringify({chunks:[{index:0,turns:parts.map((text,i)=>({text,speaker:'voice_'+(i+1)}))}],speakers:[{id:'voice_1',role:'therapist'},{id:'voice_2',role:'participant'}]});
  const data=JSON.parse(messages[1].content);return JSON.stringify({turns:data.segments.map(s=>({id:s.id,cleanText:s.text})),speakers:[{id:'voice_1',role:'therapist'},{id:'voice_2',role:'participant'}]});
 }});
 assert.deepEqual(result.formatted[0].turns.map(t=>t.text),parts);assert.equal(result.roles.get('voice_1'),'therapist');
});
test('cleanup bounds long French paragraphs as well as the number of turns',async t=>{
 const {cleanVisitTranscript}=await import('./openaiVisitCleanup.mjs');const directory=await temp(t);let calls=0;
 const segments=Array.from({length:12},()=>({speaker:'unidentified',text:'Une phrase utile. '.repeat(100)}));
 await cleanVisitTranscript({directory,segments,complete:async messages=>{calls++;const {segments}=JSON.parse(messages[1].content);assert.ok(segments.reduce((n,s)=>n+s.text.length,0)<=12000);return JSON.stringify({turns:segments.map(s=>({id:s.id,cleanText:s.text})),speakers:[{id:'unidentified',role:'unknown'}]});}});
 assert.ok(calls>1);
});
