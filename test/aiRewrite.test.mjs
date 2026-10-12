import assert from 'node:assert/strict';
import test from 'node:test';
import {
  buildRewriteMessages,
  findMissingProtectedFragments,
  findProtectedFragments,
  getLocalAiStatus,
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

test('sends the note to Ollama without streaming', async () => {
  let request;
  const result = await rewriteNote({
    text: 'La personne a du mal à entrer dans la douche.',
    mode: 'professional',
    config: {
      baseUrl: 'http://ollama.test',
      model: 'gemma3:4b',
      timeoutMs: 1_000,
    },
    fetchImpl: async (url, options) => {
      request = { url, options };
      return new Response(JSON.stringify({
        message: {
          content: "La personne rencontre des difficultés pour accéder à la douche.",
        },
      }), { status: 200 });
    },
  });

  const body = JSON.parse(request.options.body);
  assert.equal(request.url, 'http://ollama.test/api/chat');
  assert.equal(body.stream, false);
  assert.equal(body.model, 'gemma3:4b');
  assert.equal(body.keep_alive, '10m');
  assert.equal(body.messages[1].content, 'La personne a du mal à entrer dans la douche.');
  assert.equal(
    result.text,
    'La personne rencontre des difficultés pour accéder à la douche.',
  );
});

test('reports whether the configured model is installed', async () => {
  const status = await getLocalAiStatus({
    config: {
      baseUrl: 'http://ollama.test',
      model: 'gemma3:4b',
      timeoutMs: 1_000,
    },
    fetchImpl: async () => new Response(JSON.stringify({
      models: [{ name: 'gemma3:4b' }],
    }), { status: 200 }),
  });

  assert.deepEqual(status, {
    ready: true,
    model: 'gemma3:4b',
    installed: true,
  });
});


test('keeps Ollama resident and requires explicit web processing opt-in', () => {
  const config = getRewriteConfig({});
  assert.equal(config.keepAlive, '10m');
  assert.equal(config.webEnabled, false);
  const native = getRewriteConfig({ AI_REWRITE_PROVIDER: 'llama.cpp', AI_REWRITE_WEB_ENABLED: 'true' });
  assert.equal(native.provider, 'llama.cpp');
  assert.equal(native.webEnabled, true);
});

test('llama.cpp status checks readiness without sending a note', async () => {
  let requestedUrl;
  const result = await getLocalAiStatus({
    config: { provider: 'llama.cpp', webEnabled: true, baseUrl: 'http://private.test', model: 'qwen', timeoutMs: 1000 },
    fetchImpl: async (url) => {
      requestedUrl = url;
      return new Response(JSON.stringify({ status: 'ok' }));
    },
  });
  assert.equal(requestedUrl, 'http://private.test/health');
  assert.deepEqual(result, { ready: true, installed: true, model: 'qwen', webEnabled: true });
});

test('llama.cpp rewrites without reasoning and validates protected facts', async () => {
  let body;
  const config = { provider: 'llama.cpp', baseUrl: 'http://private.test', model: 'qwen', timeoutMs: 1000 };
  const fetchImpl = async (url, options) => {
    assert.equal(url, 'http://private.test/v1/chat/completions');
    body = JSON.parse(options.body);
    return new Response(JSON.stringify({ choices: [{ finish_reason: 'stop', message: { content: 'Mme Test a 82 ans et vit seule.' } }] }));
  };
  const result = await rewriteNote({ text: 'Mme Test a 82 ans et vit seul.', config, fetchImpl });
  assert.equal(result.text, 'Mme Test a 82 ans et vit seule.');
  assert.deepEqual(body.chat_template_kwargs, { enable_thinking: false });
  assert.equal(body.temperature, 0);
  await assert.rejects(rewriteNote({ text: 'Mme Test a 83 ans et vit seul.', config, fetchImpl }), { statusCode: 422 });
});

test('rejects truncated llama.cpp output before it can replace the original', async () => {
  await assert.rejects(rewriteNote({
    text: 'Une note complète.',
    config: { provider: 'llama.cpp', baseUrl: 'http://private.test', model: 'qwen', timeoutMs: 1000 },
    fetchImpl: async () => new Response(JSON.stringify({ choices: [{ finish_reason: 'length', message: { content: 'Une note' } }] })),
  }), { statusCode: 422 });
});
