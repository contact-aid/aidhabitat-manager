import test from 'node:test';import assert from 'node:assert/strict';import {plainReportText} from '../shared/plainReportText.mjs';
test('report labels lose bold while measurements and paragraphs remain intact',()=>{
 const source='**WC :** Rehausser à 48 cm.\n\n__Salle de bain :__ Paroi de 80 cm et partie mobile de 40 cm.';
 assert.equal(plainReportText(source),'WC : Rehausser à 48 cm.\n\nSalle de bain : Paroi de 80 cm et partie mobile de 40 cm.');
});
test('plain clinical values, comparison signs and data identifiers are preserved',()=>{
 const source='M. Dupont : pente < 8 %. 2*3 = 6 ; 2**3 = 8. AIDHABITAT_DATA_12. Porte 73 cm, seuil 2,5 cm.';
 assert.equal(plainReportText(source),source);
});
test('presentation wrappers are removed without exposing HTML or losing the content',()=>{
 assert.equal(plainReportText('```text\n# WC\n<strong>Hauteur :</strong> 48 cm.<br>Sans difficulté.\n```'),'WC\nHauteur : 48 cm.\nSans difficulté.');
});
