import test from 'node:test';import assert from 'node:assert/strict';
import {appendVisitResultNotes} from './visitResultNotes.mjs';
test('generated notes append without losing drawings and receipts prevent server/iPad duplicates',async()=>{
 const original={id:'note',patientId:'p',dossierId:'d',scopeId:'d',scopeType:'dossier_detail',tabKey:'Accessibilité-Notes',pageNumber:0,revision:'before',drawingJson:JSON.stringify({text:'Texte existant',strokes:[{x:1}],other:'keep'})};
 const rows=[original];let writes=0;
 const store={listNotePagesByPatient:async()=>structuredClone(rows),upsertNotePage:async p=>{assert.equal(p.expectedRevision,rows[0].revision);writes++;rows[0]={...p,id:'note',revision:p.writeId};}};
 const job={id:'recording',dossierId:'d',result:{sections:{'Accessibilité-Notes':'Complément'}}};
 const input={store,job,metadata:{patientId:'p',dossierId:'d'}};
 await appendVisitResultNotes(input);await appendVisitResultNotes(input);
 assert.equal(writes,1);const drawing=JSON.parse(rows[0].drawingJson);assert.equal(drawing.text,'Texte existant\n\nComplément');assert.deepEqual(drawing.strokes,[{x:1}]);assert.equal(drawing.other,'keep');assert.equal(drawing.visitAiInsertions['recording::Accessibilité-Notes'],'Complément');
});
test('concurrent edit is reread and retained before appending',async()=>{
 let row={id:'note',patientId:'p',dossierId:'d',scopeId:'d',scopeType:'dossier_detail',tabKey:'Sanitaires-Notes',pageNumber:0,revision:'a',drawingJson:'{"text":"Before","strokes":[]}'};let writes=0;
 const store={listNotePagesByPatient:async()=>[structuredClone(row)],upsertNotePage:async p=>{if(!writes++){row.revision='b';row.drawingJson='{"text":"New user edit","strokes":[]}';throw Object.assign(new Error('conflict'),{code:'NOTE_PAGE_REVISION_CONFLICT'});}assert.equal(p.expectedRevision,'b');row={...p};}};
 await appendVisitResultNotes({store,job:{id:'r',dossierId:'d',result:{sections:{'Sanitaires-Notes':'Addition'}}},metadata:{patientId:'p',dossierId:'d'}});
 assert.equal(JSON.parse(row.drawingJson).text,'New user edit\n\nAddition');
});
