import { build } from 'esbuild';
import { mkdir, readdir, copyFile, writeFile } from 'node:fs/promises';
const output = new URL('../../web/local-voice/', import.meta.url);
await mkdir(output, { recursive: true });
await build({ entryPoints: [new URL('worker.mjs', import.meta.url).pathname],
  bundle: true, minify: true, format: 'esm', platform: 'browser',
  outfile: new URL('worker.js', output).pathname, legalComments: 'linked' });
const runtime = new URL('node_modules/onnxruntime-web/dist/', import.meta.url);
for (const name of await readdir(runtime)) {
  if (/^ort-wasm.*\.(wasm|mjs)$/.test(name)) {
    await copyFile(new URL(name, runtime), new URL(name, output));
  }
}
await writeFile(new URL('LICENSES.md', output),
  'Transformers.js 3.8.1: Apache-2.0 (https://github.com/huggingface/transformers.js)\n' +
  'ONNX Runtime: MIT (https://github.com/microsoft/onnxruntime)\n' +
  'Whisper base: MIT (https://huggingface.co/Xenova/whisper-base)\n');
