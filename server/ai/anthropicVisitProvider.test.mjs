import test from 'node:test';
import assert from 'node:assert/strict';
import Anthropic from '@anthropic-ai/sdk';
import { anthropicRequest, anthropicSchema } from './anthropicVisitProvider.mjs';
import { createVisitProvider } from '../visitAssistant.mjs';
import { PROVIDER_QUOTA_MESSAGE } from '../openaiProviderError.mjs';

const fakeClaude = (reply) => {
  const calls = [];
  return { calls, beta: { messages: { stream: (params) => { calls.push(params); return { finalMessage: async () => reply(params) }; } } } };
};
const claudeText = (text, stop_reason = 'end_turn') => ({ id: 'msg_synthetic', model: 'claude-opus-5-5', stop_reason,
  content: [{ type: 'thinking', thinking: '' }, { type: 'text', text }], usage: { input_tokens: 10, output_tokens: 5 } });
const env = { AI_PROVIDER: 'anthropic', ANTHROPIC_API_KEY: 'synthetic', OPENROUTER_API_KEY: 'synthetic-openrouter' };

test('chat-shaped visit prompts become a Claude request with fallbacks and task effort', () => {
  const request = anthropicRequest([
    { role: 'system', content: 'Consigne' },
    { role: 'user', content: [{ type: 'text', text: 'Lis la page' }, { type: 'image_url', image_url: { url: 'data:image/png;base64,eA==' } }] },
  ], { model: 'claude-opus-5-5', maxTokens: 4096, task: 'handwriting' });
  assert.equal(request.system, 'Consigne');
  assert.deepEqual(request.messages[0].content[1], { type: 'image', source: { type: 'base64', media_type: 'image/png', data: 'eA==' } });
  assert.equal(request.output_config.effort, 'low');
  assert.equal(request.fallbacks, 'default');
  assert.deepEqual(request.betas, ['server-side-fallback-2026-07-01']);
  assert.ok(request.max_tokens >= 16000, 'thinking needs room above the answer');
  assert.ok(!('thinking' in request) && !('temperature' in request));
});

test('unsupported schema constraints are removed but field names and enums are kept', () => {
  const schema = anthropicSchema({ type: 'object', additionalProperties: false, required: ['minimum', 'items'], properties: {
    minimum: { type: 'integer', minimum: 0 },
    items: { type: 'array', maxItems: 500, minItems: 1, items: { type: 'string', enum: ['a', 'b'], maxLength: 4 } },
  } });
  assert.deepEqual(schema, { type: 'object', additionalProperties: false, required: ['minimum', 'items'], properties: {
    minimum: { type: 'integer' }, items: { type: 'array', items: { type: 'string', enum: ['a', 'b'] } } } });
});

test('with AI_PROVIDER=anthropic, audio goes to Gemini on OpenRouter and text or images to Claude', async () => {
  const openrouter = [];
  const claude = fakeClaude(() => claudeText('Seuil de 12 cm.'));
  const provider = createVisitProvider({ env, anthropicClient: claude, fetchImpl: async (url, options) => {
    openrouter.push({ url, body: JSON.parse(options.body), auth: options.headers.Authorization });
    return Response.json({ choices: [{ message: { content: JSON.stringify({ turns: [{ text: 'Le seuil fait 12 cm.', role: 'unknown', voice: 'unknown' }] }) }, finish_reason: 'stop' }] });
  } });
  assert.equal((await provider.transcribe(Buffer.from('synthetic audio'))).text, 'Le seuil fait 12 cm.');
  assert.equal(await provider.readHandwriting('data:image/png;base64,eA=='), 'Seuil de 12 cm.');
  assert.equal(openrouter.length, 1);
  assert.equal(openrouter[0].url, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(openrouter[0].auth, 'Bearer synthetic-openrouter');
  assert.equal(openrouter[0].body.model, 'google/gemini-3.5-flash-lite');
  assert.equal(openrouter[0].body.provider.zdr, true);
  assert.ok(!('temperature' in openrouter[0].body), 'privacy-compliant Gemini endpoints reject temperature');
  assert.equal(claude.calls.length, 1);
  assert.equal(claude.calls[0].model, 'claude-opus-5-5');
  assert.equal(provider.transcribeRecording, undefined, 'speaker tracking stays an OpenAI-only capability');
});

test('structured drafts are requested with a JSON schema on Claude', async () => {
  const claude = fakeClaude(() => claudeText(JSON.stringify({ facts: [], warnings: [] })));
  const provider = createVisitProvider({ env, anthropicClient: claude, fetchImpl: async () => { throw new Error('no OpenRouter call expected'); } });
  await provider.extractFacts({ transcript: [], handwrittenText: [], context: {} });
  assert.equal(claude.calls[0].output_config.format.type, 'json_schema');
  assert.equal(claude.calls[0].output_config.effort, 'high');
  assert.ok(!JSON.stringify(claude.calls[0].output_config.format.schema).includes('maxItems'));
});

test('an exhausted Claude balance, a refusal and a truncated answer are reported without provider text', async () => {
  const billing = fakeClaude(() => { throw new Anthropic.APIError(400, { type: 'error', error: { type: 'billing_error', message: 'echoed' } }, 'echoed', new Headers(), 'billing_error'); });
  const quota = createVisitProvider({ env, anthropicClient: billing });
  await assert.rejects(quota.readHandwriting('data:image/png;base64,eA=='), e => e.providerQuota === true && e.message === PROVIDER_QUOTA_MESSAGE);
  const other = fakeClaude(() => { throw new Anthropic.APIError(500, { type: 'error', error: { type: 'api_error', message: 'echoed' } }, 'echoed', new Headers(), 'api_error'); });
  await assert.rejects(createVisitProvider({ env, anthropicClient: other }).readHandwriting('data:image/png;base64,eA=='),
    e => e.statusCode === 502 && !e.providerQuota && !e.message.includes('echoed'));
  for (const stop of ['refusal', 'max_tokens']) {
    const claude = fakeClaude(() => claudeText('partial', stop));
    await assert.rejects(createVisitProvider({ env, anthropicClient: claude }).readHandwriting('data:image/png;base64,eA=='), e => e.statusCode === 502);
  }
});

test('a fenced JSON answer without schema is still parsed', async () => {
  const claude = fakeClaude(() => claudeText('```json\n{"answer":"Non précisé.","sources":[],"citations":[]}\n```'));
  const provider = createVisitProvider({ env, anthropicClient: claude });
  const answer = await provider.ask({ transcript: [{ index: 0, text: 'Bonjour.' }] }, 'Une chute ?');
  assert.equal(answer.answer, 'Non précisé.');
});
