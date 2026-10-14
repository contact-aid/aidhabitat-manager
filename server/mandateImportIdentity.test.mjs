import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import test from 'node:test';
import { assertMandateImportIdentity } from './mandateImportIdentity.mjs';

const user = { email: 'ergo@synthetic.invalid' };
const dossier = 'airtable:synthetic-dossier';
const id = `doc_mandat_${dossier}_${createHash('sha256').update(user.email).digest('hex')}`;

test('legacy multipart and chunked clients may omit dossierId after verified beneficiary access', () => {
  for (const requested of ['', undefined, null, dossier]) {
    assert.doesNotThrow(() => assertMandateImportIdentity(user, id, requested, dossier));
  }
});
test('account email normalization matches native mandate identity', () => {
  assert.doesNotThrow(() => assertMandateImportIdentity({ email: ' ERGO@synthetic.invalid ' }, id, '', dossier));
});
for (const [label, actor, documentId, requested, verified] of [
  ['other account', { email: 'other@synthetic.invalid' }, id, '', dossier],
  ['other beneficiary', user, id, '', 'different-dossier'],
  ['claimed other dossier', user, id, 'different-dossier', dossier],
  ['unverified dossier', user, id, dossier, ''],
  ['missing account', {}, id, '', dossier],
  ['tampered identity', user, `${id}-tampered`, '', dossier],
]) {
  test(`rejects ${label}`, () => assert.throws(
    () => assertMandateImportIdentity(actor, documentId, requested, verified),
    { statusCode: 403 },
  ));
}
test('ordinary scans keep the existing upload path', () => {
  assert.doesNotThrow(() => assertMandateImportIdentity(user, 'doc_synthetic_scan', '', dossier));
});
