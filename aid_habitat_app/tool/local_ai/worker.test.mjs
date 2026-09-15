import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import * as config from './config.mjs';
const source=(await readFile(new URL('worker.mjs',import.meta.url),'utf8')).replace(/^import .*;\n/gm,'');
function harness({cached=true,fail=false}={}) {
  const messages=[],requests=[];
  let resets=0;
  const self={location:{href:'https://app.example/local-ai/worker.js'},
    navigator:{gpu:{requestAdapter:async()=>({features:new Set(['shader-f16'])})}},
    fetch:async(url)=>{requests.push(url);return new Response('{}');},
    postMessage:message=>messages.push(message)};
  class MLCEngine {
    async reload(){if(!cached)await self.fetch(`${config.MODEL_URL}tokenizer.json`);}
    async unload(){}
    async resetChat(){resets++;}
    chat={completions:{create:async(request)=>{
      assert.throws(()=>self.fetch('https://external.example/notes',{method:'POST',body:request.messages[1].content}));
      if(fail)throw Error(`runtime error with ${request.messages[1].content}`);
      return {choices:[{finish_reason:'stop',message:{content:'Proposition locale.'}}]};
    }}};
  }
  vm.runInNewContext(source,{...config,self,MLCEngine,hasModelInCache:async()=>cached,URL,Error});
  return {messages,requests,resets:()=>resets,send:(method,text)=>self.onmessage({data:{id:1,method,text,mode:'professional'}})};
}
test('rewriting cannot transmit notes and clears model conversation',async()=>{
  const h=harness();await h.send('rewrite','SYNTHETIC PRIVATE NOTE');
  assert.equal(h.requests.length,0);assert.equal(h.resets(),1);
  assert.equal(h.messages.at(-1).result,'Proposition locale.');
});
test('a cold cache misses without downloading while handling a note',async()=>{
  const h=harness({cached:false});await h.send('rewrite','SYNTHETIC PRIVATE NOTE');
  assert.equal(h.requests.length,0);assert.ok(h.messages.at(-1).error);
});
test('only explicit preparation can download resources',async()=>{
  const h=harness({cached:false});await h.send('prepare');
  assert.deepEqual(h.requests,[`${config.MODEL_URL}tokenizer.json`]);
});
test('runtime errors never disclose the supplied text and still clear conversation',async()=>{
  const h=harness({fail:true});await h.send('rewrite','SYNTHETIC PRIVATE NOTE');
  assert.ok(h.messages.at(-1).error);assert.doesNotMatch(JSON.stringify(h.messages),/SYNTHETIC PRIVATE/);
  assert.equal(h.resets(),1);
});
test('multiple mounted note editors can query availability concurrently',async()=>{
  const h=harness();await Promise.all([h.send('status'),h.send('status')]);
  assert.equal(h.messages.length,2);
  assert.ok(h.messages.every(message=>message.result.supported));
});
