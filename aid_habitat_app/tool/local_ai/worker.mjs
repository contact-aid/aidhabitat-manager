import { MLCEngine, hasModelInCache } from '@mlc-ai/web-llm';
import { MODEL_ID, MODEL_BYTES, appConfig, canDownload, instructions, cleanOutput } from './config.mjs';

const config = appConfig(self.location.href);
const originalFetch = self.fetch.bind(self);
let allowDownloads = false;
// No network transport is available to the model while handling a note.
self.fetch = (input, options) => {
  if (!allowDownloads || !canDownload(input, options, self.location.href)) {
    throw new Error('Model resource missing from local cache');
  }
  return originalFetch(input, {...options, credentials: 'omit', referrerPolicy: 'no-referrer'});
};
let engine;
let loaded = false;
let busy = false;
let supported;
async function status() {
  if (supported === undefined) {
    const adapter = await self.navigator.gpu?.requestAdapter();
    supported = !!adapter && adapter.features.has('shader-f16');
  }
  return {supported, installed: supported && await hasModelInCache(MODEL_ID, config),
    ready: loaded, bytes: MODEL_BYTES};
}
async function load(downloads, id) {
  if (loaded) return;
  allowDownloads = downloads;
  engine = new MLCEngine({ appConfig: config, logLevel: 'SILENT',
    initProgressCallback: ({progress}) => self.postMessage({id, progress}) });
  try { await engine.reload(MODEL_ID); loaded = true; }
  catch (error) { await engine.unload().catch(() => {}); engine = null; throw error; }
  finally { allowDownloads = false; }
}
self.onmessage = async ({data}) => {
  const {id, method, text, mode} = data;
  if (method === 'status') {
    try { self.postMessage({id, result: await status()}); }
    catch (_) { self.postMessage({id, result: {supported: false, installed: false}}); }
    return;
  }
  if (busy) { self.postMessage({id, error: 'La reformulation est deja en cours.'}); return; }
  busy = true;
  let phase = 'validation';
  try {
    const state = await status();
    if (!state.supported) throw new Error('unsupported');
    if (method === 'prepare') {
      await load(true, id);
      self.postMessage({id, result: {...await status(), ready: true}});
    } else if (method === 'rewrite') {
      if (typeof text !== 'string' || text.length < 3 || text.length > 6000) throw new Error('length');
      phase = 'load';
      await load(false, id);
      phase = 'rewrite';
      try {
        const result = await engine.chat.completions.create({
          messages: [{role: 'system', content: instructions(mode)}, {role: 'user', content: text}],
          temperature: 0, max_tokens: 2048, extra_body: {enable_thinking: false},
        });
        if (result.choices[0]?.finish_reason !== 'stop') throw new Error('truncated');
        const output = cleanOutput(result.choices[0]?.message?.content);
        self.postMessage({id, result: output});
      } finally { await engine.resetChat(); }
    } else throw new Error('unknown');
  } catch (_) {
    // Never forward model/runtime errors which could contain patient text.
    self.postMessage({id, code: phase === 'load' ? 'model_unavailable' : 'generation_failed', error: method === 'prepare'
      ? 'Installation locale impossible. Verifiez connexion, stockage et compatibilite WebGPU.'
      : 'Reformulation locale indisponible ou note trop longue. Le texte original est conserve.'});
  } finally { busy = false; }
};
