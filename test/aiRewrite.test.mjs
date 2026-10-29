import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildRewriteMessages,
  findMissingProtectedFragments,
  findProtectedFragments,
  getAiRewriteStatus,
  REWRITE_MODEL,
  getRewriteConfig,
  normalizeRewriteMode,
  rewriteNote,
} from '../server/ai/rewrite.mjs';

test('uses the professional mode when the requested mode is unknown', () => {
  assert.equal(normalizeRewriteMode('unknown'), 'professional');
});

test('the rewrite prompt forbids invented or removed information', () => {
  const messages = buildRewriteMessages('Douche difficile.', 'concise');
  assert.equal(messages[1].content, 'Douche difficile.');
  assert.match(messages[0].content, /N'ajoute aucune information/);
  assert.match(messages[0].content, /Ne supprime aucun fait/);
  assert.match(messages[0].content, /Ne remplace pas un nom de personne/);
  assert.match(messages[0].content, /plus concise/);
});

test('protects names, measurements, ages, percentages and GIR values', () => {
  assert.deepEqual(
    findProtectedFragments(
      'Mme Jeanne Dupont, 82 ans, est classée GIR 3. Seuil de 2,5 cm et pente de 8%.',
    ),
    ['Mme Jeanne Dupont', 'GIR 3', '82 ans', '3', '2,5 cm', '8%'],
  );
  assert.deepEqual(
    findMissingProtectedFragments(
      'Mme Jeanne Dupont mesure un seuil de 2,5 cm.',
      'La bénéficiaire mesure un seuil de 2,5 cm.',
    ),
    ['Mme Jeanne Dupont'],
  );
});

test('professional report context corrects awkward phrasing and cannot inject instructions', () => {
  const [system] = buildRewriteMessages('Note fictive.', 'professional', 'beneficiary');
  assert.match(system.content, /note sur le bénéficiaire/);
  assert.match(system.content, /reformule les tournures maladroites/);
  assert.match(system.content, /Conserve les négations/);
  assert.doesNotMatch(buildRewriteMessages('Note fictive.', 'professional', 'INJECTED_CONTEXT')[0].content, /INJECTED_CONTEXT/);
});

const config = getRewriteConfig({ OPENROUTER_API_KEY: 'synthetic-key' });
const completion = (content, finish_reason = 'stop') => Response.json({ choices: [{ message: { content }, finish_reason }] });

test('rewrites exclusively with DeepSeek V4 Flash, cheapest eligible provider and reasoning off', async () => {
  let request;
  const result = await rewriteNote({ text: 'Le seuil mesure 15 cm.', config,
    fetchImpl: async (url, options) => {
      request = { url, options, body: JSON.parse(options.body) };
      return completion('Le seuil mesure 15 cm.');
    } });
  assert.equal(request.url, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(request.options.headers.Authorization, 'Bearer synthetic-key');
  assert.equal(request.body.model, 'deepseek/deepseek-v4-flash');
  assert.deepEqual(request.body.reasoning, { enabled: false });
  assert.deepEqual(request.body.provider, { sort: 'price', zdr: true, data_collection: 'deny', allow_fallbacks: false, require_parameters: true });
  assert.equal(result.text, 'Le seuil mesure 15 cm.');
  assert.equal(result.model, REWRITE_MODEL);
});

test('OpenRouter readiness does not depend on visit feature flags or legacy model settings', () => {
  assert.equal(getAiRewriteStatus({config: getRewriteConfig({})}).ready, false);
  const status = getAiRewriteStatus({config: getRewriteConfig({ OPENROUTER_API_KEY: 'synthetic-key', VISIT_ASSISTANT_ENABLED: 'false', OLLAMA_REWRITE_MODEL: 'ignored' })});
  assert.deepEqual(status, {ready:true, webEnabled:true, provider:'openrouter', model:REWRITE_MODEL});
  assert.equal(JSON.stringify(status).includes('synthetic-key'), false);
});

test('missing credentials never attempts local inference or provider access', async () => {
  let calls = 0;
  await assert.rejects(rewriteNote({text:'Note fictive.',config:getRewriteConfig({}),fetchImpl:async()=>{calls++;}}), {statusCode:503});
  assert.equal(calls,0);
});

test('rejects incomplete and empty results, altered facts and malformed responses', async () => {
  for (const response of [completion('Texte partiel', 'length'),completion(''),completion('Le seuil mesure 20 cm.'),new Response('not JSON')]) {
    await assert.rejects(rewriteNote({text:'Le seuil mesure 15 cm.',config,fetchImpl:async()=>response}), e=>[422,502].includes(e.statusCode));
  }
});

test('provider failures never expose echoed notes or credentials and never fall back locally', async () => {
  let calls = 0;
  await assert.rejects(rewriteNote({text:'Note fictive.',config,fetchImpl:async()=>{calls++;return new Response('private note synthetic-key',{status:500});}}), e => e.statusCode===502 && !e.message.includes('synthetic-key') && !e.message.includes('private note'));
  assert.equal(calls,1);
  await assert.rejects(rewriteNote({text:'Note fictive.',config,fetchImpl:async()=>{throw Object.assign(new Error('private note'),{name:'TimeoutError'});}}), {statusCode:504});
});
