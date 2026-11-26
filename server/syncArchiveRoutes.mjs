import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { SyncMutationError, SYNC_REVISION_FIELD } from './guardedMutation.mjs';
import { contextRecordToSections, contextSectionsToDatabaseFields } from './contextGuardedSync.mjs';

const sourceOf = (record) => record?.fields ?? record ?? {};

/**
 * Restaure la valeur archivée [entryId]. La valeur actuelle est d'abord
 * archivée (la restauration est donc elle-même réversible), puis l'ancienne
 * valeur est réécrite avec la même condition de révision que les envois des
 * appareils : si la fiche change pendant l'opération, rien n'est écrit.
 */
export function createSyncArchiveRestorer({ archive, readRecord, writer, contextTableId,
  allowedTableIds, newWriteId = randomUUID }) {
  return async ({ entryId, actor = null }) => {
    if (!archive?.enabled) throw new SyncMutationError(503, 'SYNC_ARCHIVE_DISABLED');
    const entry = await archive.get(entryId);
    if (!entry) throw new SyncMutationError(404, 'SYNC_ARCHIVE_ENTRY_NOT_FOUND');
    if (entry.restoredAt) throw new SyncMutationError(409, 'SYNC_ARCHIVE_ALREADY_RESTORED');
    if (!allowedTableIds.includes(entry.tableId)) {
      throw new SyncMutationError(400, 'SYNC_ARCHIVE_TABLE_NOT_RESTORABLE');
    }
    const recordId = Number(entry.recordId);
    if (!Number.isSafeInteger(recordId) || recordId <= 0) {
      throw new SyncMutationError(400, 'SYNC_ARCHIVE_RECORD_INVALID');
    }
    const observed = await readRecord(entry.tableId, recordId);
    if (!observed) throw new SyncMutationError(409, 'SYNC_RECORD_MISSING');
    const raw = sourceOf(observed);
    const isContext = entry.tableId === contextTableId;
    const current = isContext ? contextRecordToSections(raw)[entry.field] : raw[entry.field];
    const target = entry.previous;
    if (isContext && !['medicalContext', 'autonomy'].includes(entry.field)) {
      throw new SyncMutationError(400, 'SYNC_ARCHIVE_FIELD_NOT_RESTORABLE');
    }
    if (!isContext && !Object.hasOwn(raw, entry.field)) {
      throw new SyncMutationError(400, 'SYNC_ARCHIVE_FIELD_NOT_RESTORABLE');
    }
    if (isDeepStrictEqual(current ?? null, target ?? null)) {
      await archive.markRestored(entry);
      return { restored: true, unchanged: true };
    }
    const writeId = newWriteId();
    // Restauration réversible : la valeur remplacée part d'abord dans l'archive.
    await archive.record([{ field: entry.field, previous: current, next: target, baseKnown: true }], {
      source: 'restore', tableId: entry.tableId, recordId, dossierId: entry.dossierId,
      beneficiaryId: entry.beneficiaryId, writeId, actor,
    }).catch(() => { throw new SyncMutationError(503, 'SYNC_ARCHIVE_UNAVAILABLE'); });
    const fields = isContext
      ? contextSectionsToDatabaseFields({ [entry.field]: target })
      : { [entry.field]: target };
    const result = await writer({ tableId: entry.tableId, recordId,
      expectedRevision: raw[SYNC_REVISION_FIELD], writeId, fields });
    if (result?.status !== 'applied') {
      throw new SyncMutationError(result?.reason === 'revision_changed' ? 409 : 503,
        result?.reason === 'revision_changed' ? 'SYNC_ARCHIVE_RESTORE_RETRY' : 'SYNC_WRITE_UNCONFIRMED');
    }
    await archive.markRestored(entry);
    return { restored: true, unchanged: false };
  };
}

export function registerSyncArchiveRoutes(app, { requireAdmin, archive, restore,
  describeBeneficiaries = async () => ({}), tableLabels = {} }) {
  const fail = (res, error, next) => {
    if (error instanceof SyncMutationError) {
      res.status(error.status).json({ success: false, error: error.code });
      return;
    }
    if (error?.code === 'SYNC_ARCHIVE_UNAVAILABLE' || /introuvable/.test(String(error?.message))) {
      res.status(503).json({ success: false, error: 'SYNC_ARCHIVE_UNAVAILABLE' });
      return;
    }
    next(error);
  };

  app.get('/api/admin/sync-archive', requireAdmin, async (req, res, next) => {
    try {
      const entries = await archive.list({ limit: req.query.limit,
        beneficiaryId: req.query.beneficiaryId || null });
      const names = await describeBeneficiaries(
        [...new Set(entries.map((e) => e.beneficiaryId).filter(Boolean))]);
      res.json({ success: true, data: { entries: entries.map(({ rowId, ...entry }) => ({
        ...entry,
        tableLabel: tableLabels[entry.tableId] || entry.tableId,
        beneficiaryName: names[entry.beneficiaryId] || null,
      })) } });
    } catch (error) { fail(res, error, next); }
  });

  app.post('/api/admin/sync-archive/:entryId/restore', requireAdmin, async (req, res, next) => {
    try {
      const result = await restore({ entryId: req.params.entryId,
        actor: req.appUser?.email || req.appUser?.id || null });
      res.json({ success: true, data: result });
    } catch (error) { fail(res, error, next); }
  });
}
