import { build } from 'esbuild';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import {RUNTIME_FILE} from './config.mjs';
const output = new URL('../../web/local-ai/', import.meta.url);
await mkdir(output, {recursive: true});
await build({entryPoints: [new URL('worker.mjs', import.meta.url).pathname],
  bundle: true, minify: true, format: 'iife', platform: 'browser',
  outfile: new URL('worker.js', output).pathname, legalComments: 'linked'});
const wasm = new URL(RUNTIME_FILE, output);
const source = 'https://raw.githubusercontent.com/mlc-ai/binary-mlc-llm-libs/025bcaf3780fa8254f5e5efd3bfea0a5397248f4/web-llm-models/v0_2_84/base/Qwen3-1.7B-q4f16_1_cs1k-webgpu.wasm';
let bytes;
try { bytes = await readFile(wasm); } catch {
  const response = await fetch(source);
  if (!response.ok) throw new Error('Unable to download pinned model runtime');
  bytes = Buffer.from(await response.arrayBuffer());
}
if (createHash('sha256').update(bytes).digest('hex') !==
    '8161aaa4b40bccf19fcedb2f2e8c221eb9efb72d2198681f1958c9c1e05a682f') {
  throw new Error('Pinned model runtime checksum mismatch');
}
await writeFile(wasm, bytes);
await writeFile(new URL('runtime-sha256.txt', output), createHash('sha256').update(bytes).digest('hex') + '\n');
const license = await readFile(new URL('node_modules/@mlc-ai/web-llm/LICENSE', import.meta.url), 'utf8');
await writeFile(new URL('LICENSES.md', output),
  '# Local rewriting components\n\n' +
  'WebLLM 0.2.85 and the MLC model runtime: https://github.com/mlc-ai/web-llm\n\n' +
  'Qwen3-1.7B, quantized by MLC AI (q4f16_1): ' +
  'https://huggingface.co/Qwen/Qwen3-1.7B\n\n' +
  'Original model copyright Qwen Team. Apache License 2.0.\n\n' + license);
