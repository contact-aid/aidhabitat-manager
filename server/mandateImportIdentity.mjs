import { createHash } from 'node:crypto';

// Legacy native clients omit dossierId on upload. The beneficiary access
// check already resolves the authoritative dossier; never infer it from the
// client document ID or relax the account binding.
export function assertMandateImportIdentity(
  appUser, documentLocalId, requestedDossierId, verifiedDossierId,
) {
  if (!documentLocalId.startsWith('doc_mandat_')) return;
  const email = String(appUser?.email || '').trim().toLowerCase();
  const dossierId = String(verifiedDossierId || '').trim();
  const requested = String(requestedDossierId || '').trim();
  const account = createHash('sha256').update(email).digest('hex');
  if (!email || !dossierId || (requested && requested !== dossierId)
      || documentLocalId !== `doc_mandat_${dossierId}_${account}`) {
    throw Object.assign(new Error('Identité de mandat incompatible avec le compte connecté'), { statusCode: 403 });
  }
}
