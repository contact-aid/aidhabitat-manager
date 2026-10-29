import assert from 'node:assert/strict';
import test from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {once} from 'node:events';
if(!process.argv.includes('--runner')) {
  test('authenticated rewrite is OpenRouter-only even with the visit assistant disabled', {timeout:45000}, async()=>{
    const root=await mkdtemp(path.join(tmpdir(),'rewrite-routes-'));
    try {
      const result=await promisify(execFile)(process.execPath,[fileURLToPath(import.meta.url),'--runner'],{
        cwd:root,timeout:40000,env:{NODE_ENV:'test',AIDHABITAT_API_ONLY:'1',AIDHABITAT_DATA_DIR_PATH:root,
          AUTH_SESSION_SECRET:'synthetic-rewrite-secret-with-32-characters',AIDHABITAT_CONDITIONAL_SYNC:'1',NOCODB_API_URL:'https://nocodb.test.invalid',
          NOCODB_API_TOKEN:'synthetic-conditional-http-token',NOCODB_BASE_ID:'conditional_http_base',NOCODB_FORCE_REST:'1',
          OPENROUTER_API_KEY:'synthetic-openrouter-key',VISIT_ASSISTANT_ENABLED:'false'}
      });
      assert.match(result.stdout,/REWRITE_ROUTES_PASS/);
    }catch(e){assert.fail(`${e.stdout||''}\n${e.stderr||e.message}`);}
    finally {await rm(root,{recursive:true,force:true});}
  });
}else {
  const {createRestMock,ownerEmail,password}=await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock=createRestMock();const originalFetch=globalThis.fetch;let origin;let calls=0;
  globalThis.fetch=(input,init)=>{
    const url=new URL(input instanceof Request?input.url:input);
    if(url.origin===origin)return originalFetch(input,init);
    if(url.origin==='https://openrouter.ai'){
      calls++;const body=JSON.parse(init.body);assert.equal(body.model,'deepseek/deepseek-v4-flash');
      assert.equal(body.provider.sort,'price');assert.equal(body.reasoning.enabled,false);
      return Promise.resolve(Response.json({choices:[{finish_reason:'stop',message:{content:'Note corrigée.'}}]}));
    }
    // The shared auth helper still spells the preset administrator's
    // display name differently from index.mjs. Normalize only that fixture
    // startup write; the route's authentication and session check stay real.
    if (init?.method === 'PATCH' && init.body) {
      const rows = JSON.parse(init.body);
      if (Array.isArray(rows)) {
        for (const row of rows) if (row.Id === 1 && row.prenom === 'Renan') row.prenom = "Aid'habitat";
        init = {...init, body:JSON.stringify(rows)};
      }
    }
    return mock.fetch(input,init);
  };
  const {default:app}=await import('./index.mjs');const server=app.listen(0,'127.0.0.1');await once(server,'listening');origin=`http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await originalFetch(origin+'/api/ai/status')).status,401);
    const login=await originalFetch(origin+'/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:ownerEmail,password})});
    const token=(await login.json()).data.token;const headers={'content-type':'application/json','x-app-session':token};
    const status=await originalFetch(origin+'/api/ai/status',{headers});const data=(await status.json()).data;
    assert.equal(data.ready,true);assert.equal(data.provider,'openrouter');assert.equal(data.model,'deepseek/deepseek-v4-flash');assert(!JSON.stringify(data).includes('synthetic-openrouter-key'));
    const rewrite=await originalFetch(origin+'/api/ai/rewrite',{method:'POST',headers,body:JSON.stringify({text:'Note fictive.',context:'sanitary'})});
    assert.equal(rewrite.status,200);assert.equal((await rewrite.json()).data.text,'Note corrigée.');assert.equal(calls,1);
    assert.equal((await originalFetch(origin+'/api/ai/rewrite',{method:'POST',headers,body:JSON.stringify({text:'ab'})})).status,400);assert.equal(calls,1);
    assert.deepEqual(mock.violations,[]);console.log('REWRITE_ROUTES_PASS');
  }finally{await new Promise(resolve=>server.close(resolve));}
}
