import assert from 'node:assert/strict';
import test from 'node:test';
import {contextNotesForReport} from './reports/contextNotes.mjs';
const page=(tabKey,text,pageNumber=0,extra={})=>({tabKey,pageNumber,drawingJson:JSON.stringify({text,strokes:[{source:tabKey}],...extra})});
test('legacy environment replaces beneficiary prose; habits use autonomy',()=>{
  const pages=[page('Bénéficiaire-Notes','Projet de douche.'),page('Contexte de vie-Médical','Maison isolée.'),page('Contexte de vie-Médical',' Maison   isolée. ',1),page('Contexte de vie-Autonomie','Marche quotidienne.')];
  const before=structuredClone(pages);
  assert.deepEqual(contextNotesForReport(pages),{environnement:'Maison isolée.',habitudes:'Marche quotidienne.'});
  assert.deepEqual(pages,before);
});
test('canonical edits and clears suppress legacy text',()=>{
  for(const text of ['Corrigé','']){
    assert.deepEqual(contextNotesForReport([page('Bénéficiaire-Notes',text,0,{contextTextV2Initialized:true}),page('Contexte de vie-Habitudes',text,0,{contextTextV2Initialized:true}),page('Contexte de vie-Médical','Ancien environnement'),page('Contexte de vie-Autonomie','Anciennes habitudes')]),{environnement:text,habitudes:text});
  }
});
test('deleted pages and blank reports do not invent prose',()=>{
  assert.deepEqual(contextNotesForReport(),{environnement:'',habitudes:''});
  assert.deepEqual(contextNotesForReport([page('Contexte de vie-Autonomie','Ancien',0,{deleted:true})]),{environnement:'',habitudes:''});
});
