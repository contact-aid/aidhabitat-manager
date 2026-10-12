#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
// Offline metadata only. No NocoDB calls, no queue mutation, no content output.
export function verifyRecoveryEvidence(evidence) {
  const failures = [];
  const hash = /^[a-f0-9]{64}$/;
  if (evidence.backup?.encrypted !== true || evidence.backup?.completed !== true ||
      evidence.backup?.sameDevice !== true || !evidence.backup?.verifiedAt) failures.push('BACKUP_NOT_VERIFIED');
  if (!Array.isArray(evidence.operations) || evidence.operations.length !== 2) failures.push('TWO_OPERATIONS_REQUIRED');
  const ids = new Set();
  for (const op of evidence.operations || []) {
    if (!op.operationId || ids.has(op.operationId)) failures.push('OPERATION_ID_MISSING_OR_DUPLICATE');
    ids.add(op.operationId);
    // Captured before resolution, after any unsent edit has been accounted for.
    if (!hash.test(op.localDrawingSha256 || '') || op.queuedMatchesLocal !== true) failures.push('LOCAL_CONTENT_NOT_VERIFIED');
    if (op.remoteDrawingSha256 !== op.localDrawingSha256 || op.webDrawingSha256 !== op.localDrawingSha256) failures.push('CONTENT_MISMATCH');
    // The separate text_content column must also be compared, including empty text.
    if (!hash.test(op.localTextSha256 || '') || op.queuedTextMatchesLocal !== true) failures.push('LOCAL_TEXT_NOT_VERIFIED');
    if (op.remoteTextSha256 !== op.localTextSha256 || op.webTextSha256 !== op.localTextSha256) failures.push('TEXT_CONTENT_MISMATCH');
    if (op.status !== 'completed' || op.stillPending !== false || !op.acknowledgedWriteId) failures.push('OPERATION_NOT_CONFIRMED');
    if (!op.remoteReadAt || op.visualComparisonPassed !== true) failures.push('READBACK_NOT_VERIFIED');
    if (op.originalHttpStatus === 500 && (!op.diagnosis || op.diagnosis === 'unknown')) failures.push('ERROR_500_UNDIAGNOSED');
  }
  if (!evidence.operations?.some(op => op.tabKey === 'Plans' && op.pageNumber === 1)) failures.push('PLAN_PAGE_1_NOT_VERIFIED');
  return { closed: failures.length === 0, failures: [...new Set(failures)] };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv.length !== 3) throw new Error('Usage: node tools/verify-note-recovery.mjs metadata.json');
  const result = verifyRecoveryEvidence(JSON.parse(readFileSync(process.argv[2], 'utf8')));
  console.log(JSON.stringify(result, null, 2)); process.exitCode = result.closed ? 0 : 1;
}
