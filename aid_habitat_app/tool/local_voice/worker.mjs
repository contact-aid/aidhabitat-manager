import { env, pipeline } from '@huggingface/transformers';

env.allowLocalModels = false;
env.backends.onnx.wasm.wasmPaths = new URL('./', self.location.href).href;
// Firefox, Safari and non-isolated tabs all use the same CPU runtime.
env.backends.onnx.wasm.numThreads = 1;
env.backends.onnx.wasm.proxy = false;
let model;
async function prepare() {
  if (!model) {
    model = pipeline('automatic-speech-recognition', 'Xenova/whisper-base', {
      revision: '64da57285918e20ea79ea5c88eed7197933abaa8',
      device: 'wasm', dtype: 'q8',
    }).catch(error => { model = null; throw error; });
  }
  return model;
}
self.onmessage = async ({ data: { id, audio } }) => {
  try {
    const recognizer = await prepare();
    const result = audio ? await recognizer(audio, {
      language: 'french', task: 'transcribe',
      chunk_length_s: 30, stride_length_s: 5,
    }) : null;
    self.postMessage({ id, text: result?.text?.trim() || '' });
  } catch (_) {
    // Never serialize audio, transcripts or provider error bodies in logs.
    self.postMessage({ id, error: audio ? 'local-transcription-failed' : 'local-model-unavailable' });
  }
};
