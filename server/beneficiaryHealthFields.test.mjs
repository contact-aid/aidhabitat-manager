import test from 'node:test';
import assert from 'node:assert/strict';
import {mapBeneficiaryUpdatesToFields, parseOccupantsJson} from './helpers.mjs';
const references = {situations:[{id:7,fields:{libelle:'Pacsé(e)'}}],communes:[],statuts:[],dependances:[],caisses:[],caissesComp:[],baremesAnah:[]};
test('API save/read preserves fiscal year, GIR and disability details', () => {
  const occupant = {firstName:'Anne',lastName:'Test',apa:true,apaGir:'4',apaDetails:'Évaluation APA',invalidity:true,invalidityTxt:'80%',invalidityDetails:'Décision MDPH',fiscalReferenceYear:'2025'};
  const fields = mapBeneficiaryUpdatesToFields({occupants:[occupant],familySituation:'Pacsé'},references);
  const [read] = parseOccupantsJson(fields.occupants_json);
  for (const key of ['apaGir','apaDetails','invalidityDetails','fiscalReferenceYear']) assert.equal(read[key],occupant[key]);
  assert.equal(fields.situation_proprietaire_id1,7);
});
