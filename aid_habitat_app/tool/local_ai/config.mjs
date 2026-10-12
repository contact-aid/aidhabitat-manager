import { rewriteInstructions } from '../../../shared/aiRewritePrompt.mjs';
export const MODEL_ID = 'Qwen3-1.7B-q4f16_1-MLC';
export const MODEL_URL = 'https://huggingface.co/mlc-ai/Qwen3-1.7B-q4f16_1-MLC/resolve/80b3abcec6c3b3f5355dc0cc99cc4fb578f192bc/';
export const MODEL_BYTES = 968001536;
export const RUNTIME_FILE = 'rewrite-model-8161aaa4.wasm';
export function appConfig(base) {
  // IndexedDB routes cache misses through the guarded fetch, unlike Cache.add.
  return { cacheBackend: 'indexeddb', model_list: [{ model_id: MODEL_ID, model: MODEL_URL,
    model_lib: new URL(RUNTIME_FILE, base).href,
    overrides: { context_window_size: 4096 } }] };
}
export const instructions = rewriteInstructions;
export function canDownload(input, options = {}, base) {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url, base);
  const method = options.method ?? input.method ?? 'GET';
  return method === 'GET' && !options.body &&
    (url.href.startsWith(MODEL_URL) || url.href === new URL(RUNTIME_FILE, base).href);
}
export function cleanOutput(text) {
  const result = text?.replace(/^\s*<think>\s*<\/think>\s*/, '').trim();
  if (!result || /<\/?think>/i.test(result)) throw new Error('Unexpected model output');
  return result;
}
