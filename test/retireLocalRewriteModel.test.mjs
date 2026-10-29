import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import fs from 'node:fs/promises';
const html = await fs.readFile(new URL('../aid_habitat_app/web/index.html', import.meta.url), 'utf8');
const startup = html.split('<body>')[1].split('<script>')[1].split('</script>')[0];
for (const blocked of [false, true]) test(`retiring rewrite caches preserves patient stores and starts Flutter (blocked=${blocked})`, async () => {
  const removed = [], deleted = [], unregistered = [];
  const storage = new Map([['appergo-local-ai-qwen3-v1','complete'],['patient-vault','preserved']]);
  const stores = new Set(['webllm/model','webllm/config','webllm/wasm','patient-sqlite','local-voice-model']);
  const caches = {keys:async()=>['appergo-ai-shell-old','flutter-app-cache','webllm/model','patient-files','voice-assets'],delete:async name=>removed.push(name)};
  const indexedDB = {deleteDatabase(name){deleted.push(name);const request={};queueMicrotask(()=>{if(!blocked)stores.delete(name);request[blocked?'onblocked':'onsuccess']?.();});return request;}};
  let launched;
  const ready = new Promise(resolve => {launched=resolve;});
  vm.runInNewContext(startup, {window:{caches,indexedDB},caches,indexedDB,
    localStorage:{removeItem:key=>storage.delete(key)},
    navigator:{serviceWorker:{getRegistrations:async()=>[{unregister:async()=>unregistered.push('ai_offline_worker.js')}]}},
    document:{createElement:()=>({}),body:{appendChild:launched}},Promise});
  const script = await ready;
  assert.equal(script.src,'flutter_bootstrap.js');
  assert.deepEqual(deleted,['webllm/model','webllm/config','webllm/wasm']);
  assert(stores.has('patient-sqlite'));assert(stores.has('local-voice-model'));
  assert.equal(storage.get('patient-vault'),'preserved');assert(!storage.has('appergo-local-ai-qwen3-v1'));
  assert(!removed.includes('patient-files'));assert(!removed.includes('voice-assets'));
  assert.deepEqual(unregistered,['ai_offline_worker.js']);
});
