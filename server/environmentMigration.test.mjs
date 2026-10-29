import assert from 'node:assert/strict';
import test from 'node:test';
import {planEnvironmentMigration,ENVIRONMENT_MIGRATION} from './environmentMigration.mjs';
const row=(tabKey,text,pageNumber=0,extra={})=>({id:`${tabKey}-${pageNumber}`,patientId:'p',dossierId:'d',scopeType:'dossier_detail',scopeId:tabKey.startsWith('Contexte')?'p':'d',subTabKey:'',tabKey,pageNumber,revision:'00000000-0000-4000-8000-000000000001',drawingJson:JSON.stringify({text,strokes:[{original:tabKey}],...extra}),textContent:'old fallback'});
const dossier={fields:{uuid_source:'d',patient_id:'p'}};
test('old environment replaces destination prose; all original pages and handwriting survive',()=>{
 const pages=[row('Contexte de vie-Médical','Maison isolée.'),row('Contexte de vie-Médical',' Maison   isolée. ',1),row('Contexte de vie-Médical','Étage.',2),row('Bénéficiaire-Notes','Projet précédent'),row('Bénéficiaire-Notes','Autre ancienne page',1)];
 const before=structuredClone(pages);
 const {writes}=planEnvironmentMigration({pages,dossiers:[dossier]});
 assert.equal(writes.length,1);const w=writes[0],drawing=JSON.parse(w.payload.drawingJson);
 assert.equal(drawing.text,'Maison isolée.\n\nÉtage.');assert.equal(w.payload.textContent,drawing.text);
 assert.equal(drawing.contextTextV2Initialized,true);assert.equal(drawing.environmentLegacyMigration,ENVIRONMENT_MIGRATION);
 assert.deepEqual(drawing.strokes,JSON.parse(pages[3].drawingJson).strokes);assert.deepEqual(pages,before);
 assert.equal(w.payload.expectedRevision,pages[3].revision);
 const after=pages.map(p=>p.id===w.before.id?{...p,drawingJson:w.payload.drawingJson}:p);
 assert.equal(planEnvironmentMigration({pages:after,dossiers:[dossier]}).writes.length,0);
});
test('empty, cleared and deleted historical sources never overwrite destination',()=>{
 const pages=[row('Contexte de vie-Médical','',0,{noteTextInitialized:true}),row('Contexte de vie-Médical','Deleted',1,{deleted:true}),row('Bénéficiaire-Notes','Keep')];
 assert.equal(planEnvironmentMigration({pages,dossiers:[dossier]}).writes.length,0);
});
test('missing destination creates a dossier-scoped canonical note; ambiguous identities stop migration',()=>{
 const source=row('Contexte de vie-Médical','Maison');
 const input={pages:[source],dossiers:[dossier]};
 const w=planEnvironmentMigration(input).writes[0];assert.equal(w.payload.expectedRevision,null);assert.equal(w.payload.scopeId,'d');assert.equal(w.payload.pageNumber,0);
 assert.throws(()=>planEnvironmentMigration({...input,pages:[source,{...source,id:'duplicate'}]}),/Ambiguous/);
 assert.throws(()=>planEnvironmentMigration({...input,dossiers:[{fields:{uuid_source:'d',patient_id:'other'}}]}),/mismatch/);
});
