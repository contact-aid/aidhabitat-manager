import test from 'node:test';import assert from 'node:assert/strict';import vm from 'node:vm';import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../../web/local-ai/bridge.js',import.meta.url),'utf8');
function harness({persistStalls=false,estimateStalls=false,unsupported=false,offlineStalls=false,offlineFails=false,cancelOffline=false}={}){
 const requests=[],storage=new Map([['patient-vault','unchanged']]);
 class Worker{postMessage({id,method}){requests.push(method);queueMicrotask(()=>this.onmessage({data:{id,result:{supported:!unsupported,installed:method==='prepare',ready:method==='prepare'}}}));}terminate(){}}
 const window={isSecureContext:true,addEventListener(){}};
 const navigator={gpu:{},storage:{persist:()=>persistStalls?new Promise(()=>{}):Promise.resolve(true),estimate:()=>estimateStalls?new Promise(()=>{}):Promise.resolve({quota:2e9,usage:0})},serviceWorker:{getRegistration:async()=>null,register:()=>{if(cancelOffline)window.aidHabitatLocalAiCancel();return offlineFails?Promise.reject(new Error('synthetic browser refusal')):offlineStalls?new Promise(()=>{}):Promise.resolve({update:async()=>{},installing:null,waiting:null});}}};
 vm.runInNewContext(source,{window,navigator,document:{baseURI:'https://app.example/'},Worker,URL,Promise,Error,JSON,localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v),removeItem:k=>storage.delete(k)},setTimeout:(fn,ms)=>setTimeout(fn,[10000,30000].includes(ms)?5:ms),clearTimeout});
 return {window,requests,storage};
}
test('stalled persistent-storage permission cannot strand installation',async()=>{const h=harness({persistStalls:true});try{await h.window.aidHabitatLocalAiPrepare();assert.equal(h.storage.get('appergo-local-ai-qwen3-v1'),'complete');assert.equal(h.storage.get('patient-vault'),'unchanged');}finally{h.window.aidHabitatLocalAiCancel();}});
test('stalled quota check gives an actionable error before any model download',async()=>{const h=harness({estimateStalls:true});await assert.rejects(h.window.aidHabitatLocalAiPrepare(),/stockage/);assert.deepEqual(h.requests,['status']);assert.match(h.window.aidHabitatLocalAiLastError(),/stockage/);});
test('incompatible graphics yields a visible reason',async()=>{const h=harness({unsupported:true});await assert.rejects(h.window.aidHabitatLocalAiPrepare(),/WebGPU/);assert.deepEqual(h.requests,['status']);});
test('a stalled offline shell keeps the completed model available and vault intact',async()=>{const h=harness({offlineStalls:true});try{const result=JSON.parse(await h.window.aidHabitatLocalAiPrepare());assert.equal(result.installed,true);assert.equal(result.offlineReady,false);assert.match(result.warning,/OFFLINE_SHELL/);assert.equal(h.storage.get('patient-vault'),'unchanged');assert.equal(h.storage.get('appergo-local-ai-qwen3-v1'),'complete');}finally{h.window.aidHabitatLocalAiCancel();}});

test('offline rejection is explicit without invalidating the installed model',async()=>{const h=harness({offlineFails:true});try{const result=JSON.parse(await h.window.aidHabitatLocalAiPrepare());assert.match(result.warning,/OFFLINE_SHELL/);assert.equal(result.ready,true);assert.equal(h.storage.get('patient-vault'),'unchanged');}finally{h.window.aidHabitatLocalAiCancel();}});
test('cancellation during offline preparation does not report success',async()=>{const h=harness({offlineFails:true,cancelOffline:true});await assert.rejects(h.window.aidHabitatLocalAiPrepare());assert.equal(h.storage.has('appergo-local-ai-qwen3-v1'),false);assert.equal(h.storage.get('patient-vault'),'unchanged');});
test('editing pauses reuse the loaded worker while expiry and page exit release it',async()=>{
 let now=0,next=0,created=0,terminated=0;const timers=new Map(),events={};
 const window={addEventListener:(name,handler)=>events[name]=handler};
 class Worker{constructor(){created++;}postMessage({id}){queueMicrotask(()=>this.onmessage({data:{id,result:'Proposition fictive.'}}));}terminate(){terminated++;}}
 const advance=ms=>{now+=ms;for(const [id,timer] of [...timers])if(timer.at<=now){timers.delete(id);timer.fn();}};
 vm.runInNewContext(source,{window,Worker,URL,Promise,Error,JSON,navigator:{},document:{baseURI:'https://app.example/'},localStorage:{removeItem(){}},setTimeout:(fn,ms)=>{const id=++next;timers.set(id,{fn,at:now+ms});return id;},clearTimeout:id=>timers.delete(id)});
 await window.aidHabitatLocalAiRewrite('Texte fictif.','professional');advance(180000);
 await window.aidHabitatLocalAiRewrite('Autre texte fictif.','professional');
 assert.equal(created,1);assert.equal(terminated,0);
 advance(599999);assert.equal(terminated,0);advance(1);assert.equal(terminated,1);
 await window.aidHabitatLocalAiRewrite('Dernier texte fictif.','professional');assert.equal(created,2);
 events.pagehide();assert.equal(terminated,2);
});

function warmHarness({installed=true,delayRegistration=false}={}) {
 const requests=[];let completeWarm,completeRegistration,registrationStarted;
 const registrationReady = new Promise(resolve=>{registrationStarted=resolve;});
 const window={isSecureContext:true,addEventListener(){}};
 class Worker {
  postMessage({id,method}) {
   requests.push(method);
   const complete=()=>this.onmessage({data:{id,result:method==='rewrite'?'Proposition fictive.':{supported:true,installed:true,ready:false}}});
   if(method==='warmup')completeWarm=complete;else queueMicrotask(complete);
  }
  terminate(){}
 }
 vm.runInNewContext(source,{window,Worker,URL,Promise,Error,JSON,document:{baseURI:'https://app.example/'},
  navigator:{gpu:{},serviceWorker:{getRegistration:()=>{registrationStarted();return delayRegistration?new Promise(resolve=>{completeRegistration=()=>resolve(null);}):Promise.resolve(null);}}},
  localStorage:{getItem:()=>installed?'complete':null,removeItem(){}},setTimeout,clearTimeout});
 return {window,requests,registrationReady,completeRegistration:()=>completeRegistration(),completeWarm:()=>completeWarm()};
}
test('concurrent editor statuses share one cache check and one background load',async()=>{
 const h=warmHarness();
 try {
  await Promise.all([h.window.aidHabitatLocalAiStatus(),h.window.aidHabitatLocalAiStatus()]);
  assert.deepEqual(h.requests,['status','warmup']);
  const result=h.window.aidHabitatLocalAiRewrite('Note fictive.','professional');
  await Promise.resolve();assert.deepEqual(h.requests,['status','warmup']);
  h.completeWarm();assert.equal(await result,'Proposition fictive.');
  assert.deepEqual(h.requests,['status','warmup','rewrite']);
 } finally {h.window.aidHabitatLocalAiCancel();}
});
test('uninstalled models are never automatically warmed',async()=>{
 const h=warmHarness({installed:false});
 try {await h.window.aidHabitatLocalAiStatus();assert.deepEqual(h.requests,['status']);}
 finally {h.window.aidHabitatLocalAiCancel();}
});
test('cancelling a click during background load cannot restart generation',async()=>{
 const h=warmHarness();await h.window.aidHabitatLocalAiStatus();
 const result=h.window.aidHabitatLocalAiRewrite('Note fictive.','professional');
 h.window.aidHabitatLocalAiCancel();
 await assert.rejects(result,/annulée/);
 assert.deepEqual(h.requests,['status','warmup']);
});

test('a cancelled status waiting for registration cannot start a new background worker',async()=>{
 const h=warmHarness({delayRegistration:true});
 const status=h.window.aidHabitatLocalAiStatus();
 await h.registrationReady;
 h.window.aidHabitatLocalAiCancel();h.completeRegistration();await status;
 assert.deepEqual(h.requests,['status']);
});
