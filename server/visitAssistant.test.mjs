import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import express from 'express';
import { once } from 'node:events';
import { registerVisitAssistantRoutes } from './visitAssistantRoutes.mjs';
import { createVisitProvider, VisitStore, VisitProcessor, visitDigest } from './visitAssistant.mjs';

const id = 'a'.repeat(32);
const audio = Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypM4A '), Buffer.alloc(40)]);
async function fixture(t, overrides = {}, options = {}) {
  const dataDir = await fs.mkdtemp(path.join(os.tmpdir(), 'visit-assistant-'));
  t.after(() => fs.rm(dataDir, { recursive: true, force: true }));
  const app = express(); app.use(express.json());
  const calls = [];
  const { store, processor, queue } = registerVisitAssistantRoutes(app, {
    dataDir, background:options.background ?? false, retryDelayMs:0, env: { VISIT_ASSISTANT_ENABLED: 'true' },
    requireAuth: (req, res, next) => {
      if (!req.headers['x-user']) return res.sendStatus(401);
      req.appUser = { email: req.headers['x-user'] }; next();
    },
    ensureDossierRecord: async dossierId => ({ uuid_source: dossierId, ergo_id: 'Coralie' }),
    canAccessDossierRecord: (_, dossier) => dossier.uuid_source === 'dossier-a',
    field: (record, name) => record[name],
    provider: {
      transcribe: async () => { calls.push('transcribe'); return 'Aucune chute rapportée. Douche difficile d’accès.'; },
      readHandwriting: async () => { calls.push('handwriting'); return 'Seuil : 12 cm'; },
      extractFacts: async () => { calls.push('facts'); return { facts: [], warnings: [] }; },
      draft: async () => { calls.push('draft'); return { sections: { 'Accessibilité-Notes': 'Seuil mesuré à 12 cm.' }, warnings: [] }; },
      ask: async () => ({ answer: 'La douche est difficile d’accès.', sources: [0] }),
      ...overrides,
    },
  });
  t.after(() => queue?.close());
  const server = app.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const request = (suffix = '', { user = 'coralie@example.test', body, raw, headers, method = 'GET', dossier = 'dossier-a' } = {}) =>
    fetch(`${origin}/api/visit-assistant/${dossier}${suffix}`, { method,
      headers: { ...(user ? { 'x-user': user } : {}), 'content-type': raw ? 'application/octet-stream' : 'application/json', ...headers },
      body: raw ?? (body ? JSON.stringify(body) : undefined) });
  const create = (extra = {}) => request(`/${id}`, { method: 'PUT', body: { context: { existingText: {}, handwritten: [], ...extra } } });
  const upload = (index = 0, bytes = audio) => request(`/${id}/chunks/${index}`, { method: 'PUT', raw: bytes,
    headers: { 'x-audio-sha256': visitDigest(bytes), 'x-audio-duration': '60' } });
  return { request, create, upload, store, processor, queue, calls };
}

test('authentication, dossier access, ownership and traversal cannot leak a transcript', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('', { user: null })).status, 401);
  assert.equal((await f.request('', { dossier: 'dossier-b' })).status, 403);
  assert.equal((await f.create()).status, 200);
  assert.equal((await f.request(`/${id}/process`, { method: 'POST', user: 'christelle@example.test' })).status, 404);
  assert.deepEqual((await (await f.request('', { user: 'christelle@example.test' })).json()).data, []);
  assert.throws(() => f.store.dir('dossier-a', '../escape'), { statusCode: 400 });
});

test('upload retries verify content, require contiguous chunks and never rewrite context', async t => {
  const f = await fixture(t);
  await f.create({ existingText: { beneficiary: 'Texte existant' } });
  assert.equal((await f.upload(1)).status, 409);
  assert.equal((await f.upload()).status, 200);
  assert.equal((await f.upload()).status, 200);
  const other = Buffer.concat([audio, Buffer.from('different')]);
  assert.equal((await f.upload(0, other)).status, 409);
  assert.equal((await f.request(`/${id}/chunks/1`, { method: 'PUT', raw: audio,
    headers: { 'x-audio-duration': '60', 'x-audio-sha256': 'wrong' } })).status, 400);
  await f.create({ existingText: { beneficiary: 'Tentative de remplacement' } });
  const stored = await f.store.read('dossier-a', id);
  assert.equal(stored.context.existingText.beneficiary, 'Texte existant');
  assert.equal(stored.chunks.length, 1);
  assert.equal((await f.request(`/${id}/finish`, { method: 'POST', body: { chunkCount: 2 } })).status, 409);
});

test('a restart resumes after the last transcribed segment, reads handwriting and generates once', async t => {
  const f = await fixture(t);
  await f.create({ handwritten: [{ section: 'Accessibilité-Notes', page: 0, image: 'data:image/png;base64,eA==' }] });
  await f.upload();
  assert.equal((await f.request(`/${id}/finish`, { method: 'POST', body: { chunkCount: 1 } })).status, 200);
  const process = () => f.request(`/${id}/process`, { method: 'POST' });
  let job = (await (await process()).json()).data;
  assert.equal(job.transcript[0].text, 'Aucune chute rapportée. Douche difficile d’accès.');
  assert.equal(job.context, undefined, 'never echo profile or manuscript images to the client');
  const recovered = await new VisitStore(f.store.root).read('dossier-a', id);
  assert.equal(recovered.transcript.length, 1);
  job = (await (await process()).json()).data;
  assert.equal(job.status, 'reading_notes');
  job = (await (await process()).json()).data;
  assert.equal(job.status, 'organizing');
  job = (await (await process()).json()).data;
  assert.equal(job.status, 'applying');
  job = (await (await process()).json()).data;
  assert.equal(job.status, 'complete');
  await process();
  assert.deepEqual(f.calls, ['transcribe', 'handwriting', 'facts', 'draft']);
  const chat = await f.request(`/${id}/chat`, { method: 'POST', body: { question: 'Que dit-on de la douche ?' } });
  assert.deepEqual((await chat.json()).data.sources, [0]);
});

test('provider failure retains the audio and transcript progress for retry', async t => {
  let failures = 1;
  const f = await fixture(t, { transcribe: async () => {
    if (failures-- > 0) throw new Error('private provider response');
    return 'Texte récupéré';
  } });
  await f.create(); await f.upload();
  await f.request(`/${id}/finish`, { method: 'POST', body: { chunkCount: 1 } });
  const response = await f.request(`/${id}/process`, { method: 'POST' });
  assert.equal(response.status, 503);
  assert.doesNotMatch(await response.text(), /private provider response/);
  assert.deepEqual(await fs.readFile(path.join(f.store.dir('dossier-a', id), '0.m4a')), audio);
  assert.equal((await f.store.read('dossier-a', id)).transcript.length, 0);
  await f.request(`/${id}/process`, { method: 'POST' });
  assert.equal((await f.store.read('dossier-a', id)).transcript[0].text, 'Texte récupéré');
});

test('two processing requests cannot transcribe the same audio concurrently', async t => {
  let release;
  const started = Promise.withResolvers();
  const f = await fixture(t, { transcribe: async () => {
    started.resolve(); await new Promise(resolve => { release = resolve; }); return 'Transcription';
  } });
  await f.create(); await f.upload();
  await f.request(`/${id}/finish`, { method: 'POST', body: { chunkCount: 1 } });
  const first = f.request(`/${id}/process`, { method: 'POST' });
  await started.promise;
  const second = await f.request(`/${id}/process`, { method: 'POST' });
  assert.equal(second.status, 409);
  release(); assert.equal((await first).status, 200);
  assert.equal((await f.store.read('dossier-a', id)).transcript.length, 1);
});

test('OpenRouter receives enforced privacy preferences; invalid and truncated answers are rejected', async () => {
  let payload;
  const provider = createVisitProvider({ env: { OPENROUTER_API_KEY: 'synthetic-key', VISIT_AI_MODEL: 'synthetic-model' },
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://openrouter.ai/api/v1/chat/completions');
      payload = JSON.parse(options.body);
      return Response.json({ choices: [{ message: { content: '{"answer":"Absent","sources":[99]}' }, finish_reason: 'stop' }] });
    } });
  await assert.rejects(provider.ask({ transcript: [{ index: 0, text: 'Texte' }] }, 'Question'), { statusCode: 502 });
  assert.equal(payload.model, 'deepseek/deepseek-v4-flash');
  assert.deepEqual(payload.reasoning, { enabled: false });
  assert.deepEqual(payload.provider, { sort: 'price', zdr: true, data_collection: 'deny', allow_fallbacks: false, require_parameters: true });
  const truncated = createVisitProvider({ env: { OPENROUTER_API_KEY: 'synthetic-key', VISIT_AI_MODEL: 'synthetic-model' },
    fetchImpl: async () => Response.json({ choices: [{ message: { content: 'Partial' }, finish_reason: 'length' }] }) });
  await assert.rejects(truncated.rewrite([]), { statusCode: 502 });
});

test('draft preserves both profile and environment additions in their common environment note', async () => {
  const sections = { beneficiary: 'Vit en couple.', environment: 'Maison isolée.',
    autonomy: 'Marche quotidienne.', access: '', sanitary: '', project: '', summary: '' };
  const provider = createVisitProvider({env:{OPENROUTER_API_KEY:'synthetic-key',VISIT_AI_MODEL:'synthetic-model'},
    fetchImpl: async () => Response.json({choices:[{message:{content:JSON.stringify({sections,warnings:[]})},finish_reason:'stop'}]})});
  const draft = await provider.draft({context:{existingText:{}},facts:{warnings:[]}});
  assert.equal(draft.sections['Bénéficiaire-Notes'],'Vit en couple.\n\nMaison isolée.');
  assert.equal(draft.sections['Contexte de vie-Habitudes'],'Marche quotidienne.');
  assert.equal(draft.sections['Contexte de vie-Médical'],undefined);
});


test('audio and images retain compatible models while every text call uses V4 Flash', async () => {
  const calls = [];
  const provider = createVisitProvider({env:{OPENROUTER_API_KEY:'synthetic-key',
    VISIT_AI_MODEL:'expensive-old-model',VISIT_TRANSCRIPTION_MODEL:'audio-model',VISIT_VISION_MODEL:'vision-model'},
    fetchImpl:async (_,options)=>{calls.push(JSON.parse(options.body));return Response.json({choices:[{message:{content:'Texte'},finish_reason:'stop'}]});}});
  await provider.rewrite([{role:'user',content:'Texte synthétique'}]);
  await provider.transcribe(Buffer.from('synthetic audio'));
  await provider.readHandwriting('data:image/png;base64,eA==');
  assert.deepEqual(calls.map(c=>c.model),['deepseek/deepseek-v4-flash','audio-model','vision-model']);
  assert.ok(calls.every(c=>c.provider.sort==='price' && c.provider.zdr===true));
  assert.equal(calls[1].messages[0].content[1].type,'input_audio');
  assert.equal(calls[2].messages[0].content[1].type,'image_url');
});

test('unconfigured audio model uses an audio-compatible low-cost default, never the text model', async () => {
  let body;
  const audit=[];
  const provider=createVisitProvider({env:{OPENROUTER_API_KEY:'synthetic-key',VISIT_AI_MODEL:'old-model'},
    onUsage:entry=>audit.push(entry),fetchImpl:async (_,options)=>{
      body=JSON.parse(options.body);
      return Response.json({usage:{cost:0.0006},choices:[{message:{content:'Aucune chute rapportée.'},finish_reason:'stop'}]});
    }});
  assert.equal(await provider.transcribe(Buffer.from('synthetic audio')),'Aucune chute rapportée.');
  assert.equal(body.model,'google/gemini-3.1-flash-lite');
  assert.deepEqual(body.reasoning,{enabled:false});
  assert.equal(body.max_tokens,4096);
  assert.equal(body.provider.zdr,true);
  assert.equal(body.provider.allow_fallbacks,false);
  assert.equal(audit[0].task,'transcription');
  assert.equal(audit[0].model,body.model);
});


test('finish starts server processing without client process requests and exposes durable progress', async t => {
  const f=await fixture(t,{}, {background:true});
  await f.create();await f.upload();
  assert.equal((await f.request(`/${id}/finish`,{method:'POST',body:{chunkCount:1}})).status,200);
  await f.queue.enqueue('dossier-a',id);
  const jobs=(await (await f.request()).json()).data;
  assert.equal(jobs[0].status,'complete');assert.equal(jobs[0].transcribedChunks,1);assert.equal(jobs[0].chunkCount,1);assert.ok(jobs[0].notesAppliedAt);
  assert.deepEqual(f.calls,['transcribe','facts','draft']);
  const poll=(await (await f.request(`/${id}/process`,{method:'POST'})).json()).data;
  assert.deepEqual(poll.result.sections,{});
  assert.deepEqual(jobs[0].result.sections,{'Accessibilité-Notes':'Seuil mesuré à 12 cm.'});
});


test('long visit extraction has enough output budget and audits costs without source content', async () => {
  let body;const audit=[];
  const provider=createVisitProvider({env:{OPENROUTER_API_KEY:'synthetic-key'},
    onUsage:entry=>audit.push(entry),fetchImpl:async (_,options)=>{
      body=JSON.parse(options.body);
      return Response.json({id:'generation-fiction',model:'deepseek/deepseek-v4-flash',
        usage:{cost:0.001,prompt_tokens:40000,completion_tokens:14000,completion_tokens_details:{reasoning_tokens:0}},
        choices:[{message:{content:JSON.stringify({facts:[],warnings:[]})},finish_reason:'stop'}]});}});
  await provider.extractFacts({transcript:[{index:0,text:'PRIVATE SYNTHETIC SOURCE'}],context:{},handwrittenText:[]});
  assert.equal(body.max_tokens,32768);assert.deepEqual(body.reasoning,{enabled:false});
  assert.equal(body.response_format.type,'json_schema');assert.equal(body.response_format.json_schema.strict,true);
  assert.deepEqual(body.response_format.json_schema.schema.required,['facts','warnings']);
  assert.equal(audit.length,1);assert.equal(audit[0].task,'facts');assert.equal(audit[0].cost,0.001);
  assert.equal(audit[0].completionTokens,14000);assert.ok(!JSON.stringify(audit).includes('PRIVATE SYNTHETIC SOURCE'));
});
