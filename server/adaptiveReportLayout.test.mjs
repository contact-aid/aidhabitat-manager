import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, StandardFonts, PDFArray, decodePDFRawStream } from 'pdf-lib';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { generateVisitReport } from './reports/generateVisitReport.mjs';
import { reportOccupants, reportOccupantStatuses, wrapReportLines } from './reports/adaptiveReportLayout.mjs';
import { resolveReportPigPloermel } from './reports/pigPloermel.mjs';
async function extract(bytes) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(),'adaptive-report-'));
  try { const file=path.join(directory,'test.pdf'); await fs.writeFile(file,bytes); return execFileSync('pdftotext',['-raw',file,'-'],{encoding:'utf8'}); }
  finally { await fs.rm(directory,{recursive:true,force:true}); }
}
const patient={firstName:'Anne',lastName:'EXEMPLE',numberPeople:3,occupants:[
  {firstName:'Anne',lastName:'EXEMPLE',birthDate:'1950-02-01',dependenceTxt:'Canne'},
  {firstName:'Jean',lastName:'DEUX',birthDate:'1949-03-02',dependenceTxt:'Déambulateur'},
  {firstName:'Marie',lastName:'TROIS',birthDate:'1978-05-06',dependenceTxt:'Aucune'},
]};
test('occupant count follows household size and preserves intentional empty fields',()=>{
  for(const count of [1,2,3]) assert.equal(reportOccupants({...patient,numberPeople:count}).length,count);
  assert.equal(reportOccupants({...patient,occupants:[{firstName:''}]} )[0].firstName,'');
  assert.equal(reportOccupants({firstName:'Seul'}).length,1);
});
test('glyph-based wrapping preserves every character of long tokens within the page width',async()=>{
  const doc=await PDFDocument.create();const font=await doc.embedFont(StandardFonts.Helvetica);
  const word='ANTICONSTITUTIONNELLEMENT'.repeat(15);
  const lines=wrapReportLines(word,font,11,100);
  assert.equal(lines.join(''),word);assert(lines.every(line=>font.widthOfTextAtSize(line,11)<=100));
});
test('long habits and summary continue in place, accessibility uses full height, and numbering stays continuous',async()=>{
  const paragraph='La personne bénéficie d’un environnement adapté pour ses activités quotidiennes et ses déplacements.\n';
  const options={dossier:{patient,housing:{}},sanitaires:{},observations:{
    resumePreconisations:paragraph.repeat(110)+'FIN_RESUME_VERIFIE',
    accessibiliteObservation:paragraph.repeat(20)+'FIN_ACCES_VERIFIE',
  },contexteNotes:[{tabKey:'Contexte de vie-Autonomie',textContent:paragraph.repeat(95)+'FIN_HABITUDES_VERIFIEES'}],pigPloermelResolved:true,fetchImageBytes:async()=>null};
  const before=structuredClone(options.dossier);
  const {bytes,stats}=await generateVisitReport(options);
  assert.deepEqual(options.dossier,before);
  assert(stats.habitsFlow.addedPages>0);assert(stats.summaryFlow.addedPages>0);
  assert.equal(stats.accessibilityFlow.firstPageCapacity,28);
  assert.equal(stats.emptyPlanPagesRemoved,2);
  const pages=(await extract(bytes)).split('\f').filter(t=>t.trim());
  assert(pages[2].includes('Occupant 3'));assert(pages[2].includes('06/05/1978'));
  const habits=pages.findIndex(t=>t.includes('Habitudes de vie (suite)'));
  const housing=pages.findIndex(t=>t.includes('Le logement'));
  assert(habits>0 && habits<housing);
  const all=pages.join('\n');
  for(const token of ['FIN_RESUME_VERIFIE','FIN_ACCES_VERIFIE','FIN_HABITUDES_VERIFIEES']) assert(all.includes(token),token);
  assert.match(all,/0\s*€/);
  assert(!pages.some(t=>t.includes('Plan des travaux préconisés')||t.includes('Plan du logement avant travaux')));
  const document = await PDFDocument.load(bytes);
  for(let i=1;i<document.getPageCount();i++) {
    const content=document.getPage(i).node.Contents();
    const refs=content instanceof PDFArray ? content.asArray() : [content];
    const decoded=refs.map(ref=>Buffer.from(decodePDFRawStream(document.context.lookup(ref)).decode()).toString('latin1')).join('\n');
    const labels=[...decoded.matchAll(/<([0-9A-Fa-f]+)> Tj/g)];
    assert.equal(labels.at(-1)[1].toLowerCase(),Buffer.from(String(i)).toString('hex'));
  }
});
test('a populated plan remains in the report while the opposite empty phase is removed',async()=>{
  const buffer=await sharp({create:{width:400,height:300,channels:3,background:'#ff9922'}}).png().toBuffer();
  const {bytes,stats}=await generateVisitReport({dossier:{patient},sanitaires:{},observations:{},documents:[{id:'plan',tags:['Visite - Plan après']}],fetchImageBytes:async()=>({buffer,mimeType:'image/png'})});
  assert.equal(stats.emptyPlanPagesRemoved,1);
  const text=await extract(bytes);assert(text.includes('Plan des travaux préconisés'));assert(!text.includes('Plan du logement avant travaux'));
});
for(const value of [[true],[false],[],[0],undefined]) {
 test(`PIG uses the verified Airtable checkbox ${JSON.stringify(value)}`,async()=>{
  const id='recmHnOwbM7choQvu';let requested;
  const result=await resolveReportPigPloermel(`airtable:${id}`,{token:'synthetic-token',fetchImpl:async url=>{
   requested=url;return {ok:true,json:async()=>({records:[{id,fields:{'PIG ploermel':value}}]})};
  }});
  assert.equal(result,value?.includes(true)??false);assert.equal(requested.searchParams.get('filterByFormula'),`RECORD_ID()="${id}"`);
 });
}
test('PIG read failure blocks incorrect AMO pricing and non-Airtable dossiers do not call Airtable',async()=>{
  await assert.rejects(resolveReportPigPloermel('airtable:recmHnOwbM7choQvu',{token:'synthetic',fetchImpl:async()=>({ok:false,status:503})}),/503/);
  assert.equal(await resolveReportPigPloermel('local-dossier',{fetchImpl:()=>{throw new Error('Unexpected read');}}),null);
});

test('APA and MDPH identify eligible occupants and omit negative stale statuses',()=>{
  const p = {numberPeople:3, apa:true,apaGir:'1',invalidity:true,invalidityTxt:'Ancienne valeur',occupants:[
    {apa:true,apaGir:'4',invalidity:true,invalidityTxt:'Entre 50 et 79%'},
    {apa:false,apaGir:'2',invalidity:false,invalidityTxt:'80%'},
    {apa:true,apaGir:'GIR 6',invalidity:true,invalidityTxt:'Supérieur à 80%'},
  ]};
  assert.deepEqual(reportOccupantStatuses(p),{apa:'Occupant 1 GIR 4, Occupant 3 GIR 6',mdph:'Occupant 1 Entre 50 et 79%, Occupant 3 Supérieur à 80%'});
  assert.deepEqual(reportOccupantStatuses({occupants:[{apa:false,invalidity:false}]}),{apa:'',mdph:''});
  assert.deepEqual(reportOccupantStatuses({apa:true,apaGir:'4',invalidity:true,invalidityTxt:'80%'}),{apa:'Occupant 1 GIR 4',mdph:'Occupant 1 80%'});
});
test('PDF displays occupant-specific APA and MDPH instead of household values',async()=>{
 const {bytes}=await generateVisitReport({dossier:{patient:{...patient,occupants:patient.occupants.map((o,i)=>({...o,apa:i!==1,apaGir:i===0?'4':'6',invalidity:i!==1,invalidityTxt:i===0?'Entre 50 et 79%':'80%'}))}},fetchImageBytes:async()=>null});
 const page=(await extract(bytes)).split('\f')[2];
 assert.match(page,/Bénéficiaire APA : Occupant 1 GIR 4, Occupant 3 GIR 6/);
 assert.match(page,/Reconnaissance d.invalidité MDPH : Occupant 1 Entre 50 et 79%, Occupant 3 80%/);
 assert(!page.includes('Occupant 2 GIR'));
});

test('health details follow each occupant GIR and disability percentage only when enabled', () => {
  const p = {numberPeople: 3, occupants: [
    {apa:true, apaGir:'4', apaDetails:'Évaluation du 12 octobre', invalidity:true, invalidityTxt:'80%', invalidityDetails:'Décision MDPH'},
    {apa:true, apaGir:'6', apaDetails:'   ', invalidity:true, invalidityTxt:'50%', invalidityDetails:''},
    {apa:false, apaDetails:'DÉTAIL_PÉRIMÉ_APA', invalidity:false, invalidityDetails:'DÉTAIL_PÉRIMÉ_MDPH'},
  ]};
  assert.deepEqual(reportOccupantStatuses(p), {
    apa:'Occupant 1 GIR 4 : Évaluation du 12 octobre, Occupant 2 GIR 6',
    mdph:'Occupant 1 80% : Décision MDPH, Occupant 2 50%',
  });
});

test('PDF preserves long health details in continuation without displaying unchecked details', async () => {
  const {bytes} = await generateVisitReport({dossier:{patient:{...patient, familySituation:'Pacsé', occupants:[
    {...patient.occupants[0], apa:true, apaGir:'4', apaDetails:'Évaluation GIR détaillée. '.repeat(90)+'FIN_GIR_DETAIL', invalidity:true, invalidityTxt:'80%', invalidityDetails:'Décision MDPH détaillée. '.repeat(90)+'FIN_MDPH_DETAIL'},
    {...patient.occupants[1], apa:false, apaDetails:'STALE_APA_DETAIL', invalidity:false, invalidityDetails:'STALE_MDPH_DETAIL'},
  ]}},fetchImageBytes:async()=>null});
  const text = await extract(bytes);
  assert(text.includes('Pacsé'));
  assert(text.includes('Occupant 1 GIR 4 : Évaluation GIR'));
  assert(text.includes('Occupant 1 80% : Décision MDPH'));
  assert(text.includes('FIN_GIR_DETAIL'));
  assert(text.includes('FIN_MDPH_DETAIL'));
  assert(!text.includes('STALE_APA_DETAIL'));
  assert(!text.includes('STALE_MDPH_DETAIL'));
});
