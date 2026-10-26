import assert from 'node:assert/strict';
import test from 'node:test';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';
if (!process.argv.includes('--runner')) {
  test('housing empty levels remain explicit on the JSON wire for legacy conflict review', {timeout:45000}, async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'housing-levels-'));
    try {
      const result = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
        cwd:root, timeout:40000, env:{NODE_ENV:'test', AIDHABITAT_API_ONLY:'1',
          AIDHABITAT_DATA_DIR_PATH:root, AUTH_SESSION_SECRET:'synthetic-baseline-secret',
          AIDHABITAT_CONDITIONAL_SYNC:'1', NOCODB_API_URL:'https://nocodb.test.invalid',
          NOCODB_API_TOKEN:'synthetic-conditional-http-token', NOCODB_BASE_ID:'conditional_http_base',NOCODB_FORCE_REST:'1'},
      });
      assert.match(result.stdout,/HOUSING_LEVELS_PASS/);
    } catch(e) {assert.fail(`${e.stdout || ''}\n${e.stderr || e.message}`);}
    finally {await rm(root,{recursive:true,force:true});}
  });
} else {
  const {createRestMock,patientId,dossierId,ownerEmail,password,tables}=await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const mock=createRestMock({referenceRows:{caisses:[{Id:501,nom:'CNAV'},{Id:502,nom:'CNBF'}]}});
  const originalFetch=globalThis.fetch;let origin;
  globalThis.fetch=(input,init)=>new URL(input instanceof Request ? input.url : input).origin===origin
    ?originalFetch(input,init):mock.fetch(input,init);
  const {default:app}=await import('./index.mjs');
  const server=app.listen(0,'127.0.0.1');await once(server,'listening');origin=`http://127.0.0.1:${server.address().port}`;
  try {
    const login=await originalFetch(origin+'/api/auth/login',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({email:ownerEmail,password})});
    const token=(await login.json()).data.token;
    const headers={'content-type':'application/json','x-app-session':token};
    const row = mock.row('logement');
    for (const [stored, expected] of [[undefined, null], [null, null], ['', null], [2, 2], ['3', 3], [0, 0]]) {
      row.nombre_niveaux = stored;
      const response = await originalFetch(origin + '/api/dossiers', {headers});
      assert.equal(response.status, 200);
      const housing = (await response.json()).find(d => d.id === dossierId).housing;
      assert.ok(Object.hasOwn(housing, 'levels'), 'JSON must retain an empty comparison field');
      assert.equal(housing.levels, expected);
    }
    assert.equal(mock.patches().filter(call => call.path.includes(tables.logement)).length, 0, 'reads must not mutate the housing');
    assert.deepEqual(mock.violations,[]);
    console.log('HOUSING_LEVELS_PASS');
  } finally {await new Promise(r=>server.close(r));}
}
