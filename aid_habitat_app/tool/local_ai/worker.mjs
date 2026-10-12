import { MLCEngine, hasModelInCache } from '@mlc-ai/web-llm';
import { MODEL_ID, MODEL_BYTES, appConfig, canDownload, instructions, cleanOutput } from './config.mjs';
import {rewriteParts} from './rewrite_parts.mjs';

const config = appConfig(self.location.href);
const originalFetch = self.fetch.bind(self);
let allowDownloads = false;
let downloadFailure;
// No network transport is available to the model while handling a note.
self.fetch = (input, options) => {
  if (!allowDownloads || !canDownload(input, options, self.location.href)) {
    throw new Error('Model resource missing from local cache');
  }
  return originalFetch(input, {...options, credentials: 'omit', referrerPolicy: 'no-referrer'})
    .then(response => {
      if (!response.ok) downloadFailure = 'model_network';
      return response;
    }, error => { downloadFailure = 'model_network'; throw error; });
};
let engine;
let loaded = false;
let busy = false;
let supported;
let reason;
let segmented = false;
async function status() {
  if (supported === undefined) {
    const adapter = await self.navigator.gpu?.requestAdapter({powerPreference: 'high-performance'});
    supported = !!adapter && adapter.features.has('shader-f16');
    if (supported) {
      // Match the pinned runtime's actual requirements before any download.
      const limits = adapter.limits;
      segmented = limits.maxStorageBuffersPerShaderStage === 9;
      supported = limits.maxStorageBuffersPerShaderStage >= 9 &&
        limits.maxComputeWorkgroupStorageSize >= 32768 &&
        limits.maxBufferSize >= 268435456 &&
        limits.maxStorageBufferBindingSize >= 134217728 &&
        limits.maxComputeInvocationsPerWorkgroup >= 256;
      if (!supported) reason = 'gpu_limits';
    }
  }
  return {supported, reason, segmented, installed: supported && (loaded || await hasModelInCache(MODEL_ID, config)),
    ready: loaded, bytes: MODEL_BYTES};
}
async function load(downloads, id) {
  if (loaded) return;
  allowDownloads = downloads;
  downloadFailure = undefined;
  engine = new MLCEngine({ appConfig: config, logLevel: 'SILENT',
    initProgressCallback: ({progress}) => self.postMessage({id, progress}) });
  try { await engine.reload(MODEL_ID); loaded = true; }
  catch (error) { await engine.unload().catch(() => {}); engine = null; throw error; }
  finally { allowDownloads = false; }
}
self.onmessage = async ({data}) => {
  const {id, method, text, mode, context} = data;
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
    } else if (method === 'warmup') {
      phase = 'load';
      self.postMessage({id, phase: 'Chargement du moteur local…'});
      await load(false, id);
      self.postMessage({id, result: {ready: true}});
    } else if (method === 'rewrite') {
      if (typeof text !== 'string' || text.length < 3 || text.length > 6000) throw new Error('length');
      phase = 'load';
      self.postMessage({id, phase: loaded ? 'Reformulation en cours…' : 'Chargement du moteur local…'});
      await load(false, id);
      phase = 'rewrite';
      try {
        const prompt = instructions(mode, context);
        let parts = [text];
        if (segmented) {
          // These fields are pinned to WebLLM 0.2.85. An unavailable tokenizer
          // fails closed rather than sending an oversized prompt to the GPU.
          const tokenizer = engine.loadedModelIdToPipeline?.get(MODEL_ID)?.tokenizer;
          if (typeof tokenizer?.encode !== 'function') throw new Error('tokenizer');
          parts = rewriteParts(text, part => tokenizer.encode(prompt + '\n' + part).length);
        }
        const outputs = [];
        for (let index = 0; index < parts.length; index++) {
        await engine.resetChat();
        self.postMessage({id, progress: index / parts.length, phase: `Reformulation du passage ${index + 1}/${parts.length}…`});
        const result = await engine.chat.completions.create({
          messages: [{role: 'system', content: prompt}, {role: 'user', content: parts[index]}],
          temperature: 0, max_tokens: 2048, extra_body: {enable_thinking: false},
        });
        if (result.choices[0]?.finish_reason !== 'stop') throw new Error('truncated');
        outputs.push(cleanOutput(result.choices[0]?.message?.content));
        }
        const output = outputs.map((value, index) => value + (index < parts.length - 1
          ? (parts[index].match(/\s+$/)?.[0] || ' ') : '')).join('');
        self.postMessage({id, result: output});
      } finally { await engine.resetChat(); }
    } else throw new Error('unknown');
  } catch (error) {
    // Never forward model/runtime errors which could contain patient text.
    // During preparation no report text enters the worker. Only a fixed
    // category leaves it, never an exception, URL, device name or stack.
    let code = phase === 'load' ? 'model_unavailable' : 'generation_failed';
    if (method === 'prepare') {
      const detail = String(error?.message || '');
      code = downloadFailure || (/webgpu|gpu|shader|device.{0,20}lost|out of memory|allocate.*buffer/i.test(detail)
        ? 'model_gpu' : error?.name === 'QuotaExceededError' || /quota.{0,30}exceed|indexeddb.{0,30}(denied|unavailable|transaction)/i.test(detail)
        ? 'model_storage' : 'model_runtime');
    }
    self.postMessage({id, code, error: method === 'prepare'
      ? 'Installation locale impossible. Verifiez connexion, stockage et compatibilite WebGPU.'
      : 'Reformulation locale indisponible ou note trop longue. Le texte original est conserve.'});
  } finally { busy = false; }
};
