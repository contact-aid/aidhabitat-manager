import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyRecoveryEvidence } from './verify-note-recovery.mjs';
const valid = () => ({backup:{encrypted:true,completed:true,sameDevice:true,verifiedAt:'2026-10-05'},operations:[1,2].map(n=>({operationId:`fake-${n}`,tabKey:n===1?'Plans':'unknown',pageNumber:1,localDrawingSha256:'a'.repeat(64),queuedMatchesLocal:true,localTextSha256:'b'.repeat(64),queuedTextMatchesLocal:true,remoteTextSha256:'b'.repeat(64),webTextSha256:'b'.repeat(64),remoteDrawingSha256:'a'.repeat(64),webDrawingSha256:'a'.repeat(64),status:'completed',stillPending:false,acknowledgedWriteId:`write-${n}`,remoteReadAt:'2026-10-05',visualComparisonPassed:true,originalHttpStatus:n===2?500:409,diagnosis:'synthetic diagnosis'}))});
test('closure requires both original contents and completed operations',()=>{
 assert.equal(verifyRecoveryEvidence(valid()).closed,true);
 for(const change of [e=>e.backup.encrypted=false,e=>e.operations.pop(),e=>e.operations[1].diagnosis='unknown',e=>e.operations[0].remoteDrawingSha256='b'.repeat(64),e=>e.operations[1].stillPending=true,e=>delete e.operations[0].localTextSha256,e=>e.operations[0].webTextSha256='c'.repeat(64),e=>e.operations[0].queuedTextMatchesLocal=false,e=>e.operations[0].visualComparisonPassed=false]){const e=valid();change(e);assert.equal(verifyRecoveryEvidence(e).closed,false);}
});
