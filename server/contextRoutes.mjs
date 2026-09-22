import { createContextGuardedSync, contextRecordToSections, contextServerReference,
  CONTEXT_RECORD_FIELDS } from './contextGuardedSync.mjs';
import { SyncMutationError } from './guardedMutation.mjs';

export function registerContextRoutes(app, {
  requireAuth, enabled, creationReady = false, tableId, writer, createRecord, queryAll,
  ensureDossierRecord, canAccessDossierRecord, field,
}) {
  const read = async (dossierId) => {
    const records = await queryAll(tableId, { fields: CONTEXT_RECORD_FIELDS,
      where: `(dossier_id,eq,${JSON.stringify(dossierId)})` });
    if (records.some(record => String(field(record, 'dossier_id')) !== String(dossierId))) {
      throw new SyncMutationError(503, 'CONTEXT_RECORD_READ_INVALID');
    }
    if (records.length > 1) throw new SyncMutationError(503, 'CONTEXT_DUPLICATES_REQUIRE_MIGRATION');
    return records[0] ?? null;
  };
  const mutate = enabled ? createContextGuardedSync({ tableId,
    readByDossierId: read, writer, createRecord: (...args) => {
      if (!creationReady) throw new SyncMutationError(503, 'CONTEXT_CREATION_NOT_PREPARED');
      return createRecord(...args);
    } }) : null;
  const authorize = async (req) => {
    if (!enabled) throw new SyncMutationError(503, 'CONTEXT_SYNC_NOT_PREPARED');
    const dossier = await ensureDossierRecord(req.params.dossierId);
    if (!canAccessDossierRecord(req.appUser, dossier)) throw new SyncMutationError(403, 'CONTEXT_RECORD_FORBIDDEN');
    return dossier;
  };
  app.get('/api/contextes/:dossierId', requireAuth, async (req, res, next) => {
    try {
      const dossier = await authorize(req);
      const dossierId = field(dossier, 'uuid_source');
      const record = await read(dossierId);
      res.json({ dossierId, ...contextRecordToSections(record),
        serverReference: record ? contextServerReference(record) : null });
    } catch (error) { next(error); }
  });
  app.put('/api/contextes/:dossierId', requireAuth, async (req, res, next) => {
    try {
      const dossier = await authorize(req);
      const dossierId = field(dossier, 'uuid_source');
      const result = await mutate({ dossierId,
        beneficiaryId: field(dossier, 'patient_id'), dossierRecordId: Number(dossier.id),
        beneficiaryRecordId: field(dossier, 'beneficiaires_id'),
        updates: req.body?.updates, concurrency: req.body?.concurrency,
        authorizeObserved: (record) => String(field(record, 'dossier_id')) === String(dossierId),
      });
      res.json({ success: true, data: { dossierId, serverReference: result.serverReference } });
    } catch (error) {
      if (error instanceof SyncMutationError && error.status === 409) {
        res.status(409).json({ conflict: true, error: error.code, remoteData: error.observed });
      } else { next(error); }
    }
  });
}
