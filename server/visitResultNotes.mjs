import crypto from 'node:crypto';
import {contextNotesForReport} from './reports/contextNotes.mjs';
import {VISIT_SECTIONS,visitError} from './visitAssistant.mjs';

// Share the receipt format with the iPad so an older client cannot insert the
// same generated paragraph a second time after pulling the server note.
export async function appendVisitResultNotes({store,job,metadata}) {
  const {patientId,dossierId}=metadata;
  if(!patientId||dossierId!==job.dossierId||!job.result?.sections)throw visitError(409,'Identité ou résultat de visite invalide.');
  for(const [tabKey,addition] of Object.entries(job.result.sections)) {
    if(!Object.values(VISIT_SECTIONS).includes(tabKey)||typeof addition!=='string')throw visitError(409,'Rubrique de visite invalide.');
    if(!addition.trim())continue;
    let done=false;
    for(let attempt=0;attempt<3&&!done;attempt++) {
      const pages=(await store.listNotePagesByPatient(patientId)).filter(p=>p.dossierId===dossierId);
      const targets=pages.filter(p=>p.tabKey===tabKey&&Number(p.pageNumber)===0&&!p.subTabKey);
      if(targets.length>1)throw visitError(409,'Plusieurs notes existent pour cette rubrique.');
      const target=targets[0];
      if(target&&(target.scopeType!=='dossier_detail'||![patientId,dossierId].includes(target.scopeId)))throw visitError(409,'Portée de note ambiguë.');
      const drawing=JSON.parse(target?.drawingJson||'{"version":1,"strokes":[]}');
      if(drawing.deleted===true)throw visitError(409,'La note a été supprimée.');
      const receipt=`${job.id}::${tabKey}`;
      const receipts=drawing.visitAiInsertions??{};
      if(Object.hasOwn(receipts,receipt)){done=true;break;}
      let original=typeof drawing.text==='string'?drawing.text:String(target?.textContent||'');
      if(['Bénéficiaire-Notes','Contexte de vie-Habitudes'].includes(tabKey)&&!drawing.contextTextV2Initialized) {
        const context=contextNotesForReport(pages);
        original=tabKey==='Bénéficiaire-Notes'?context.environnement:context.habitudes;
      }
      const text=`${original}${original?'\n\n':''}${addition.trim()}`;
      try {
        await store.upsertNotePage({...target,...metadata,notePageId:target?.id??crypto.randomUUID(),
          tabKey,subTabKey:'',pageNumber:0,scopeType:'dossier_detail',scopeId:target?.scopeId??dossierId,
          textContent:text,drawingJson:JSON.stringify({...drawing,text,noteTextInitialized:true,
            ...(['Bénéficiaire-Notes','Contexte de vie-Habitudes'].includes(tabKey)?{contextTextV2Initialized:true}:{}),
            visitAiInsertions:{...receipts,[receipt]:addition.trim()}}),
          expectedRevision:target?.revision??null,writeId:crypto.randomUUID(),
          previewDataUrl:target?.previewDataUrl??'',layoutKind:target?.layoutKind??'freeform'});
        done=true;
      } catch(error) {if(error.code!=='NOTE_PAGE_REVISION_CONFLICT'||attempt===2)throw error;}
    }
  }
}
