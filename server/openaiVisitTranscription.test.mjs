import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createOpenAIRecordingTranscriber} from './openaiVisitTranscription.mjs';
import {createVisitProvider} from './visitAssistant.mjs';
import {getRewriteConfig,rewriteNote} from './ai/rewrite.mjs';
const env={AI_PROVIDER:'openai',OPENAI_API_KEY:'synthetic-only'};
const completion=text=>Response.json({choices:[{message:{content:text},finish_reason:'stop'}]});
test('visit text uses direct OpenAI Luna, no router fallback or unnecessary reasoning',async()=>{
  const calls=[];
  const provider=createVisitProvider({env,fetchImpl:async(url,options)=>{
    calls.push({url,body:JSON.parse(options.body)});return completion('Texte fictif.');
  }});
  await provider.rewrite([{role:'user',content:'Texte fictif.'}]);
  assert.equal(calls[0].url,'https://api.openai.com/v1/chat/completions');
  assert.equal(calls[0].body.model,'gpt-6-luna');
  assert.equal(calls[0].body.reasoning_effort,'none');assert.equal(calls[0].body.store,false);
  assert.equal(calls[0].body.provider,undefined);
  const unavailable=createVisitProvider({env,fetchImpl:async()=>new Response('PRIVATE KEY OR DATA',{status:500})});
  await assert.rejects(unavailable.rewrite([]),error=>error.statusCode===502&&!error.message.includes('PRIVATE'));
});
test('manual note rewrite also uses OpenAI and preserves protected measurements',async()=>{
  const config=getRewriteConfig(env);let actual;
  const result=await rewriteNote({text:'Le seuil mesure 12 cm.',config,fetchImpl:async(url,options)=>{
    actual={url,body:JSON.parse(options.body)};return completion('Le seuil mesure 12 cm.');
  }});
  assert.equal(actual.url,'https://api.openai.com/v1/chat/completions');assert.equal(result.model,'gpt-6-luna');
});
test('whole-visit voice identities, cleanup guards and cached audio survive retries',async t=>{
  const directory=await fs.mkdtemp(path.join(os.tmpdir(),'openai-visit-'));t.after(()=>fs.rm(directory,{recursive:true,force:true}));
  const job={id:'synthetic',dossierId:'synthetic',author:'Christelle',chunks:[{duration:60},{duration:60}]};
  const segments=[
    {start:0,end:2,speaker:'A',text:'Euh, le seuil mesure 12 cm.'},
    {start:4,end:5,speaker:'B',text:'Euh...'},
    {start:61,end:65,speaker:'B',text:'Je ne suis pas tombé.'},
    {start:66,end:68,speaker:'C',text:'Je viens voir mon père.'},
  ];let uploads=0,cleanups=0;
  const texts=['Euh, le seuil mesure 12 cm. Euh...','Je ne suis pas tombé. Je viens voir mon père.'];
  await Promise.all([0,1].map(i=>fs.writeFile(path.join(directory,i+'.m4a'),String(i))));
  const transcribe=createOpenAIRecordingTranscriber({env,prepareAudio:async()=>Buffer.from('synthetic'),probeAudioDuration:async()=>120,
    fetchImpl:async(url,options)=>{
      uploads++;if(options.body.get('model')==='gpt-transcribe')return Response.json({text:texts[Number(await options.body.get('file').text())],languages:[{code:'fr'}]});
      assert.equal(options.body.get('response_format'),'diarized_json');
      assert.equal(options.body.get('chunking_strategy'),'auto');return Response.json({segments});
    },complete:async(messages,options)=>{
      if(options.task==='transcript_dialogue')return JSON.stringify({chunks:[{index:0,turns:[{text:segments[0].text,speaker:'voice_1'},{text:segments[1].text,speaker:'voice_2'}]},{index:1,turns:[{text:segments[2].text,speaker:'voice_2'},{text:segments[3].text,speaker:'voice_3'}]}],speakers:[{id:'voice_1',role:'therapist'},{id:'voice_2',role:'participant'},{id:'voice_3',role:'participant'}]});
      cleanups++;
      if(cleanups===1) throw Error('synthetic interrupted cleanup');
      return JSON.stringify({turns:[{id:0,cleanText:'Le seuil est adapté.'},{id:1,cleanText:''},
        {id:2,cleanText:'Je suis tombé.'},{id:3,cleanText:'Je viens voir mon père.'}],
        speakers:[{id:'voice_1',role:'therapist'},{id:'voice_2',role:'participant'},{id:'voice_3',role:'participant'}]});
    }});
  await assert.rejects(transcribe({job,directory}),/interrupted/);
  const result=await transcribe({job,directory});
  assert.equal(uploads,3);assert.equal(cleanups,2);
  assert.equal(result[0].turns[0].cleanText,segments[0].text); // measurement loss rejected
  assert.equal(result[1].turns[0].cleanText,segments[2].text); // negation loss rejected
  assert.equal(result[0].turns[1].cleanText,'');
  assert.equal(result[0].turns[1].speakerId,result[1].turns[0].speakerId);
  assert.notEqual(result[1].turns[0].speakerName,result[1].turns[1].speakerName);
  assert.equal(result[0].turns[0].roleConfirmed,false);
  assert.equal(result[1].text,'Je ne suis pas tombé.\nJe viens voir mon père.');
  assert.deepEqual(await transcribe({job,directory}),result);assert.equal(uploads,3);assert.equal(cleanups,2);
});

test('long visit prompts retain original citations and speaker identity without repeated display metadata',async()=>{
  const source='Aucune chute. Le seuil mesure 12 cm.';
  const turns=Array.from({length:500},()=>({speakerId:'voice_1',speakerName:'Christelle',role:'therapist',roleConfirmed:true,
    text:source,cleanText:'PRIVATE DISPLAY ONLY',voice:'unknown',speakerNumber:1,startSeconds:5,endSeconds:9}));
  const job={transcript:[{index:0,startSeconds:0,text:source,turns}]};const before=JSON.stringify(job);let payload;
  const provider=createVisitProvider({env,fetchImpl:async(url,options)=>{
    payload=JSON.parse(JSON.parse(options.body).messages[1].content);
    return completion(JSON.stringify({answer:source,sources:[0],citations:[{index:0,quote:source}]}));
  }});
  assert.equal((await provider.ask(job,'Quel seuil ?')).citations[0].quote,source);
  assert.equal(payload.transcript[0].text,source);
  assert.deepEqual(payload.speakers,[{id:'voice_1',name:'Christelle',role:'therapist',roleConfirmed:true}]);
  assert.ok(JSON.stringify(payload).length<before.length/3);
  assert.ok(!JSON.stringify(payload).includes('PRIVATE DISPLAY ONLY'));
  assert.equal(JSON.stringify(job),before);
});

test('joined speaker turns keep exact source line breaks for cross-turn citations',async()=>{
 const first='Le seuil mesure 12 cm.',second='Aucune chute rapportée.',text=first+'\n'+second;
 const job={transcript:[{index:0,text,turns:[{speakerId:'voice_1',text:first},{speakerId:'voice_1',text:second}]}]};
 const provider=createVisitProvider({env,fetchImpl:async(url,options)=>{
  const payload=JSON.parse(JSON.parse(options.body).messages[1].content);
  assert.equal(payload.transcript[0].turns[0].text,text);
  return completion(JSON.stringify({answer:text,sources:[0],citations:[{index:0,quote:text}]}));
 }});
 assert.equal((await provider.ask(job,'Seuil et chutes ?')).citations[0].quote,text);
});
