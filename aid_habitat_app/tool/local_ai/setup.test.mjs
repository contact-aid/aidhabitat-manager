import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../../web/local-ai/setup.js',import.meta.url),'utf8');
test('an older bridge still gives a visible failure and a working retry button',async()=>{
  const elements=new Map();
  for(const id of ['status','result','install','cancel','progress'])elements.set(id,{hidden:false,disabled:false,textContent:'',removeAttribute(){},addEventListener(event,handler){this[event]=handler;}});
  const api={aidHabitatLocalAiPrepare:async()=>{throw Error('synthetic failure');},aidHabitatLocalAiStatus:async()=>JSON.stringify({supported:true}),aidHabitatLocalAiCancel(){}};
  vm.runInNewContext(source,{...api,window:api,document:{getElementById:id=>elements.get(id)},setInterval:()=>1,clearInterval(){},JSON});
  await Promise.resolve();
  await elements.get('install').click();
  assert.equal(elements.get('status').textContent,'Installation interrompue');
  assert.match(elements.get('result').textContent,/INSTALLER_UNAVAILABLE/);
  assert.equal(elements.get('install').disabled,false);
});
