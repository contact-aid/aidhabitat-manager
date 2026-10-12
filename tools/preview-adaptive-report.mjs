import fs from 'node:fs/promises';
import { generateVisitReport } from '../server/reports/generateVisitReport.mjs';
import { PDFDocument } from 'pdf-lib';
import sharp from 'sharp';
const out = new URL('../output/pdf/', import.meta.url);
await fs.mkdir(out, { recursive: true });
const repeated = Array.from({length: 22}, (_,i) => `Paragraphe ${i+1}. La personne souhaite conserver son autonomie à domicile. Les déplacements et les activités quotidiennes nécessitent un environnement accessible, des équipements adaptés et un accompagnement approprié.`).join('\n\n');
const png = await sharp({ create: { width: 640, height: 420, channels: 3, background: '#dde8ee' } }).png().toBuffer();
const dossier = { id: 'synthetic-preview', natureAccompagnement: 'complet', visitDate: '2026-10-12', patient: {
  firstName:'Anne',lastName:'EXEMPLE',numberPeople:3,occupationStatus:'Propriétaire',familySituation:'Mariée',apa:true,apaGir:'4',invalidity:true,invalidityTxt:'Entre 50 et 79%',homeHelp:true,homeHelpTxt:'Aide ménagère deux fois par semaine',zipCode:'56120',
  occupants:[{firstName:'Anne',lastName:'EXEMPLE',birthDate:'1950-02-01',dependenceTxt:'Canne'}, {firstName:'Jean',lastName:'EXEMPLE',birthDate:'1949-04-03',dependenceTxt:'Déambulateur'}, {firstName:'Marie',lastName:'EXEMPLE',birthDate:'1978-05-21',dependenceTxt:'Aucune'}],
},housing:{typology:'Maison',accessibilityNotes:'',heatingDetails:{electric:true},rdc:true}};
const documents = Array.from({length:12}, (_,i) => ({id:`p${i}`,title:`Photo ${i+1}`,tags:[i<2?'Visite - Logement':i<6?'Visite - Accessibilité':'Visite - Sanitaires']}));
const { bytes,stats }=await generateVisitReport({ dossier, pigPloermelResolved:true, observations:{accessibiliteObservation:repeated.slice(0,1700),resumePreconisations:repeated}, contexteNotes:[{tabKey:'Contexte de vie-Médical',textContent:'Exemple de contexte et d’environnement du bénéficiaire.'},{tabKey:'Contexte de vie-Autonomie',textContent:repeated}], documents, recommendations:[{wikiItemId:'w',wikiTitle:'Main courante',note:'Pose d’une main courante pour sécuriser les déplacements.'}], fetchImageBytes:async()=>({buffer:png,mimeType:'image/png'}) });
await fs.writeFile(new URL('Aperçu rapport adaptatif.pdf',out),bytes);
console.log(JSON.stringify({pages:(await PDFDocument.load(bytes)).getPageCount(),stats},null,2));
