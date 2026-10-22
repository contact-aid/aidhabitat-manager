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
  test('beneficiary scalar funds do not contaminate the occupant comparison baseline', {timeout:45000}, async () => {
    const root = await mkdtemp(path.join(tmpdir(), 'patient-baseline-'));
    try {
      const result = await promisify(execFile)(process.execPath, [fileURLToPath(import.meta.url), '--runner'], {
        cwd:root, timeout:40000, env:{NODE_ENV:'test', AIDHABITAT_API_ONLY:'1',
          AIDHABITAT_DATA_DIR_PATH:root, AUTH_SESSION_SECRET:'synthetic-baseline-secret',
          AIDHABITAT_CONDITIONAL_SYNC:'1', NOCODB_API_URL:'https://nocodb.test.invalid',
          NOCODB_API_TOKEN:'synthetic-conditional-http-token', NOCODB_BASE_ID:'conditional_http_base',NOCODB_FORCE_REST:'1'},
      });
      assert.match(result.stdout,/BASELINE_PASS/);
    } catch(e) {assert.fail(`${e.stdout || ''}\n${e.stderr || e.message}`);}
    finally {await rm(root,{recursive:true,force:true});}
  });
} else {
  const {createRestMock,patientId,dossierId,ownerEmail,password}=await import('./test-fixtures/conditionalRoutes.rest.mjs');
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
    const row=mock.row('beneficiaire');
    row.caisses_de_retraite_id=502;row.caisse_retraite_principale={Id:502,nom:'CNBF'};
    row.occupants_json=JSON.stringify([{firstName:'Synthetic',lastName:'Patient',caisseRetraitePrincipale:'Aucune',homeHelp:true}]);
    row.aide_a_domicile=false;
    const response=await originalFetch(origin+'/api/dossiers',{headers});
    const patient=(await response.json()).find(d=>d.id===dossierId).patient;
    assert.equal(patient.caisseRetraitePrincipale,'CNBF');
    assert.equal(patient.occupants[0].caisseRetraitePrincipale,'Aucune');
    const body={caisseRetraitePrincipale:'CNAV',homeHelp:true,
      occupants:patient.occupants.map(p=>({...p,caisseRetraitePrincipale:'CNAV'})),
      concurrency:{version:1,collectionContract:'collections-v2',writeId:randomUUID(),
        baseValues:{caisseRetraitePrincipale:patient.caisseRetraitePrincipale,homeHelp:patient.homeHelp,occupants:patient.occupants}}};
    const save=()=>originalFetch(origin+`/api/beneficiaires/${patientId}`,{method:'PATCH',headers,body:JSON.stringify(body)});
    const saved=await save();assert.equal(saved.status,200,await saved.text());
    assert.equal(row.caisses_de_retraite_id,501);
    assert.equal(JSON.parse(row.occupants_json)[0].caisseRetraitePrincipale,'CNAV');
    const writes=mock.patches().length;
    assert.equal((await save()).status,200,'same write must replay without another mutation');
    assert.equal(mock.patches().length,writes);
    assert.deepEqual(mock.violations,[]);
    console.log('BASELINE_PASS');
  } finally {await new Promise(r=>server.close(r));}
}
