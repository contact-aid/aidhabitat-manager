import test from 'node:test';import assert from 'node:assert/strict';
import {createVisitProvider} from './visitAssistant.mjs';
import {rewriteNote,getRewriteConfig} from './ai/rewrite.mjs';
const env={AI_PROVIDER:'openai',OPENAI_API_KEY:'synthetic-only'};
const completion=value=>Response.json({choices:[{message:{content:typeof value==='string'?value:JSON.stringify(value)},finish_reason:'stop'}]});
test('handwriting uses a precise image model while normal text stays economical',async()=>{
 const calls=[];const provider=createVisitProvider({env,fetchImpl:async(url,options)=>{calls.push(JSON.parse(options.body));return completion('Poêle à bois, bois compressé.');}});
 await provider.readHandwriting('data:image/png;base64,eA==');await provider.rewrite([{role:'user',content:'Texte fictif.'}]);
 assert.equal(calls[0].model,'gpt-6.1-sol');assert.equal(calls[0].reasoning_effort,'low');assert.equal(calls[0].store,false);
 assert.equal(calls[0].messages[0].content[1].image_url.detail,'original');
 assert.equal(calls[1].model,'gpt-6-luna');assert.equal(calls[1].reasoning_effort,'none');
});
test('image-derived equipment facts keep their source and thematic blank lines through drafting',async()=>{
 const handwriting={section:'Accessibilité-Notes',page:0,text:'Poêle à bois, bois compressé. Volets : manipulation sans difficulté. Porte de garage basculante : pas de difficulté.'};
 const facts={facts:[{section:'access',text:'Poêle à bois utilisant du bois compressé.',sources:[{kind:'handwriting',index:0}]}],warnings:[]};
 const expected='Le logement dispose d’un poêle à bois utilisant du bois compressé.\n\nLes volets sont manipulés sans difficulté. La porte de garage basculante est utilisée sans difficulté.';
 let stage=0;
 const provider=createVisitProvider({env,fetchImpl:async(url,options)=>{
  const request=JSON.parse(options.body),source=JSON.parse(request.messages[1].content);
  if(stage++===0){assert.deepEqual(source.handwriting,[handwriting]);return completion(facts);}
  assert.deepEqual(source.handwrittenNotes,[handwriting]);assert.deepEqual(source.extractedFacts,facts);
  return completion({sections:{beneficiary:'',environment:'',autonomy:'',access:expected,sanitary:'',project:'',summary:''},warnings:[]});
 }});
 const job={transcript:[],handwrittenText:[handwriting],context:{existingText:{}}};job.facts=await provider.extractFacts(job);
 assert.equal((await provider.draft(job,null)).sections['Accessibilité-Notes'],expected);
});
test('manual professional reformulation preserves paragraph breaks and protected measurements',async()=>{
 const text='La porte mesure 87 cm.\n\nLe logement dispose d’un poêle à bois.';
 const result=await rewriteNote({text,context:'housing',config:getRewriteConfig(env),fetchImpl:async()=>completion(text)});
 assert.equal(result.text,text);
});

test('structured themes are ordered and separated even when model fields arrive in a different order',async()=>{
 const sections={beneficiary:{profil:'',foyer:''},environment:{logement:'',entourageEtAides:''},autonomy:{sante:'',mobilite:'',activitesQuotidiennes:''},
  access:{ouvrantsEtManipulation:'Les volets sont manipulés sans difficulté.',chauffage:'Poêle à bois utilisant du bois compressé.',circulationEtNiveaux:'',exterieurEtEntree:'Sort à pied par la porte-fenêtre.'},
  sanitary:{salleDeBainEquipements:'',salleDeBainUtilisation:'',wcEquipements:'',wcUtilisation:''},project:{souhaits:'',projet:''},summary:{preconisations:''}};
 const provider=createVisitProvider({env,fetchImpl:async()=>completion({sections,warnings:[]})});
 const result=await provider.draft({context:{existingText:{}},facts:{facts:[],warnings:[]}},null);
 assert.equal(result.sections['Accessibilité-Notes'],'Sort à pied par la porte-fenêtre.\n\nPoêle à bois utilisant du bois compressé.\n\nLes volets sont manipulés sans difficulté.');
});

test('generated and reformulated notes remove unsupported bold labels before returning to clients',async()=>{
 const source='WC : Rehausser à 48 cm.';
 const provider=createVisitProvider({env,fetchImpl:async()=>completion({sections:{beneficiary:'',environment:'',autonomy:'',access:'',sanitary:'',project:'',summary:'**WC :** Rehausser à 48 cm.'},warnings:[]})});
 assert.equal((await provider.draft({context:{existingText:{}},facts:{facts:[],warnings:[]}},null)).sections['Préconisations-Résumé'],source);
 const result=await rewriteNote({text:source,context:'recommendations',config:getRewriteConfig(env),fetchImpl:async()=>completion('**WC :** Rehausser à 48 cm.')});
 assert.equal(result.text,source);
});
