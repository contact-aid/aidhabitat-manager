const legacyUnassignedLabels = new Set(['', 'e1', 'user']);

export const normalizeDossierAssignment = (value) => {
  const label = String(value ?? '').trim();
  return legacyUnassignedLabels.has(label.toLowerCase()) ? '' : label;
};

export const canAccessDossierAssignment = (appUser, assignment) => {
  if (appUser?.role === 'ADMIN') return true;
  const assignedErgo = normalizeDossierAssignment(assignment);
  const expectedErgo = normalizeDossierAssignment(appUser?.ergoLabel);
  return assignedErgo !== '' && expectedErgo !== '' && assignedErgo === expectedErgo;
};

// A dossier synthesized during a read is not an explicitly assigned creation.
// Omitting ergo_id keeps it admin-visible without granting another account access.
export const buildImplicitDossierFields = ({
  uuidSource,
  patientId,
  beneficiaryRecordId,
  createdAt,
}) => ({
  uuid_source: uuidSource,
  patient_id: patientId,
  beneficiaires_id: beneficiaryRecordId,
  status: 'À visiter',
  created_at: createdAt,
});
