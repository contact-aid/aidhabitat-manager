import test from 'node:test';
import assert from 'node:assert/strict';
import {canDownload, MODEL_URL, RUNTIME_FILE, instructions, appConfig, cleanOutput} from './config.mjs';
const base = 'https://app.example/local-ai/worker.js';

test('only pinned model resources and the local runtime can download', () => {
  assert.equal(canDownload(`${MODEL_URL}params_shard_0.bin`, {}, base), true);
  assert.equal(canDownload(new URL(`${MODEL_URL}tokenizer.json`), {}, base), true);
  assert.equal(canDownload(new Request(`${MODEL_URL}tokenizer.json`), {}, base), true);
  assert.equal(canDownload(RUNTIME_FILE, {}, base), true);
  for (const url of ['https://example.org/leak', '/api/ai/rewrite', `${MODEL_URL}../other/file`, 'https://huggingface.co/other/model']) {
    assert.equal(canDownload(url, {}, base), false);
  }
});
test('uploads are forbidden even to model hosts', () => {
  assert.equal(canDownload(MODEL_URL, {method: 'POST', body: 'private'}, base), false);
  assert.equal(canDownload(MODEL_URL, {body: 'private'}, base), false);
  assert.equal(canDownload(new Request(MODEL_URL, {method: 'POST', body: 'private'}), {}, base), false);
});
test('the model is pinned and limited to a bounded context', () => {
  assert.equal(appConfig(base).cacheBackend, 'indexeddb');
  const record = appConfig(base).model_list[0];
  assert.equal(record.model, MODEL_URL);
  assert.equal(record.model_lib, `https://app.example/local-ai/${RUNTIME_FILE}`);
  assert.equal(record.overrides.context_window_size, 4096);
});
test('all rewriting modes preserve facts, negations and placeholders', () => {
  for (const mode of ['correct', 'concise', 'professional']) {
    const prompt = instructions(mode);
    assert.match(prompt, /N'ajoute aucun fait/);
    assert.match(prompt, /Conserve les negations/);
    assert.match(prompt, /AIDHABITAT_DATA_/);
  }
});
test('removes empty model markers but refuses reasoning or empty output', () => {
  assert.equal(cleanOutput('<think>\n\n</think>\nTexte.'),'Texte.');
  assert.equal(cleanOutput('Texte.'),'Texte.');
  assert.throws(()=>cleanOutput('<think>Hidden reasoning</think>Texte.'));
  assert.throws(()=>cleanOutput(''));
});
