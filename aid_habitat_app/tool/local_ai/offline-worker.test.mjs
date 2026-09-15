import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {createHash, webcrypto} from 'node:crypto';

const template = await readFile(new URL('offline-worker.template.js', import.meta.url), 'utf8');
function harness({fail = false} = {}) {
  const listeners = new Map(), stored = new Map(), deleted = [];
  let network = true;
  const assets = [{path:'index.html',sha256:createHash('sha256').update('shell').digest('hex')}];
  const self = {
    registration:{scope:'https://app.example/'},location:{origin:'https://app.example'},
    clients:{claim:async()=>{}},skipWaiting:async()=>{},
    addEventListener:(name, handler)=>listeners.set(name,handler),
  };
  const caches = {
    open:async()=>({put:async(url,response)=>stored.set(url,response),match:async(url)=>stored.get(url)?.clone()}),
    delete:async(name)=>{deleted.push(name);}, keys:async()=>['patient-cache','appergo-ai-shell-old'],
  };
  vm.runInNewContext(template.replace('__BUILD__','"test"').replace('__ASSETS__',JSON.stringify(assets)), {
    self,caches,URL,Response,Uint8Array,crypto:webcrypto,
    fetch:async()=>{if(!network)throw Error('offline');return new Response(fail?'wrong build':'shell');},
  });
  return {listeners,stored,deleted,offline:()=>{network=false;}};
}
test('installs only verified static assets, then retains unrelated caches',async()=>{
  const h=harness();
  await new Promise((resolve,reject)=>h.listeners.get('install')({waitUntil:p=>p.then(resolve,reject)}));
  assert.deepEqual([...h.stored.keys()],['https://app.example/index.html']);
  await new Promise((resolve,reject)=>h.listeners.get('activate')({waitUntil:p=>p.then(resolve,reject)}));
  assert.deepEqual(h.deleted,['appergo-ai-shell-old']);
});
test('a mixed or corrupt build fails without deleting previous offline versions',async()=>{
  const h=harness({fail:true});
  await assert.rejects(new Promise((resolve,reject)=>h.listeners.get('install')({waitUntil:p=>p.then(resolve,reject)})));
  assert.deepEqual(h.deleted,['appergo-ai-shell-test']);
});
test('API, patient files, query strings and non-GET are never intercepted',()=>{
  const h=harness();
  for(const [url,method] of [['/api/dossiers','GET'],['/uploads/doc.pdf','GET'],['/index.html?token=private','GET'],['/index.html','POST'],['https://other.example/index.html','GET']]){
    h.listeners.get('fetch')({request:{url:new URL(url,'https://app.example').href,method},respondWith:()=>assert.fail('private request intercepted')});
  }
});
test('root navigation reopens the exact installed shell without a server',async()=>{
  const h=harness();
  await new Promise((resolve,reject)=>h.listeners.get('install')({waitUntil:p=>p.then(resolve,reject)}));
  h.offline();
  const response=await new Promise(resolve=>h.listeners.get('fetch')({request:{url:'https://app.example/',method:'GET',mode:'navigate'},respondWith:resolve}));
  assert.equal(await response.text(),'shell');
});
