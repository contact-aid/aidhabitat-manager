import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, StandardFonts, PDFArray, decodePDFRawStream } from 'pdf-lib';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { generateVisitReport } from './reports/generateVisitReport.mjs';
import { reportOccupants, wrapReportLines } from './reports/adaptiveReportLayout.mjs';
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
