import test from 'node:test';import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {rewriteParts} from './rewrite_parts.mjs';
import {adaptGpuRuntime} from './gpu_runtime_compat.mjs';
test('passages preserve every character, identifier, decimal and negation',()=>{
 const text='AIDHABITAT_DATA_001 utilise une canne de 1,5 m. Elle ne chute pas.\n\n'.repeat(25);
 const parts=rewriteParts(text,text=>text.length+20,120);
 assert.equal(parts.join(''),text);assert.ok(parts.every(text=>text.length+20<=120));
 assert.ok(parts.length>1);assert.ok(parts.every(text=>!text.includes('AIDHABITAT_DATA_')||text.includes('AIDHABITAT_DATA_001')));
});
test('a long sentence can split on words without losing characters',()=>{
 const text='Une observation fictive sans ponctuation '.repeat(100);
 const parts=rewriteParts(text,text=>text.length,90);
 assert.equal(parts.join(''),text);assert.ok(parts.every(part=>part.length<=90));
});
test('an unsplittable token fails instead of truncating',()=>{
 assert.throws(()=>rewriteParts('x'.repeat(1000),text=>text.length,90),/unsplittable/);
});
test('the pinned runtime only reduces its request for nine-buffer adapters',async()=>{
 const source=await readFile(new URL('node_modules/@mlc-ai/web-llm/lib/index.js',import.meta.url),'utf8');
 assert.match(adaptGpuRuntime(source),/maxStorageBuffersPerShaderStage === 9 \? 9 : 10/);
 assert.throws(()=>adaptGpuRuntime('changed source'),/contract changed/);
});
