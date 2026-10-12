import test from 'node:test';
import assert from 'node:assert/strict';
import { selectLegacyNoteAlias } from './noteLegacyAlias.mjs';
const address = { patientId:'patient-98', dossierId:'dossier-98', scopeType:'dossier_detail', tabKey:'Contexte de vie-Autonomie', subTabKey:'', pageNumber:0 };
const record = {id:'remote',fields:{beneficiaire_id:'patient-98',dossier_id:'dossier-98',scope_type:'dossier_detail',scope_id:'patient-98',tab_key:'Contexte de vie-Autonomie',sub_tab_key:'',page_number:0,app_sync_revision:'revision'}};
test('legacy autonomy page preserves identity, revision and contents',()=>{
  assert.equal(selectLegacyNoteAlias([record],address),record);
  assert.equal(record.fields.app_sync_revision,'revision');
});
test('missing or ambiguous pages are never inferred',()=>{
  for (const rows of [[],[record,record]]) assert.equal(selectLegacyNoteAlias(rows,address),null);
});
test('foreign patient, dossier, scope, tab, subtab and page are rejected',()=>{
  for(const key of ['beneficiaire_id','dossier_id','scope_type','scope_id','tab_key','sub_tab_key','page_number']) {
    const changed=structuredClone(record); changed.fields[key]=key==='page_number'?1:'foreign';
    assert.equal(selectLegacyNoteAlias([changed],address),null,key);
  }
});
test('independent dossier notes cannot revert to patient scope',()=>{
  for(const tabKey of ['Bénéficiaire-Notes','notes_rapides']) assert.equal(selectLegacyNoteAlias([record],{...address,tabKey}),null);
});
