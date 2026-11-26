import { randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';

// Étape 1 du plan de synchronisation : avant qu'un envoi remplace une valeur
// que l'appareil n'avait pas vue, le serveur en garde une copie. Si la copie
// échoue, l'écriture est refusée de façon temporaire (le client réessaie) et
// rien n'est écrasé. Aucune règle de synchronisation n'est modifiée ici.

export const SYNC_ARCHIVE_TABLE_NAME = process.env.NOCODB_SYNC_ARCHIVE_TABLE_NAME || 'sync_archive';

export const SYNC_ARCHIVE_SCHEMA_SPEC = {
  tableName: SYNC_ARCHIVE_TABLE_NAME,
  fields: [
    ['uuid_source', 'SingleLineText'],
    ['archived_at', 'DateTime'],
    ['source', 'SingleLineText'],
    ['table_id', 'SingleLineText'],
    ['record_id', 'SingleLineText'],
    ['dossier_id', 'SingleLineText'],
    ['beneficiaire_id', 'SingleLineText'],
    ['field_name', 'SingleLineText'],
    ['previous_value', 'LongText'],
    ['next_value', 'LongText'],
    ['base_known', 'Checkbox'],
    ['write_id', 'SingleLineText'],
    ['actor', 'SingleLineText'],
    ['restored_at', 'DateTime'],
  ],
};

export class SyncArchiveUnavailableError extends Error {
  constructor(cause) {
    super('SYNC_ARCHIVE_UNAVAILABLE', { cause });
    this.code = 'SYNC_ARCHIVE_UNAVAILABLE';
  }
}

const isEmpty = (value) => value == null || value === ''
  || (Array.isArray(value) && value.length === 0);

/**
 * Valeurs qu'un envoi va remplacer alors que l'appareil ne les avait pas vues.
 * - champ inchangé par l'envoi : rien à garder ;
 * - ancienne valeur vide : rien à perdre ;
 * - valeur de départ connue et identique à la valeur actuelle : l'appareil
 *   remplace sa propre valeur, ce n'est pas le travail de quelqu'un d'autre.
 * Une valeur de départ absente est inconnue : on archive par prudence.
 */
export function overwrittenValues({ patch, observed, baseFields = {},
  equals = (_key, a, b) => isDeepStrictEqual(a, b) }) {
  const entries = [];
  for (const [key, next] of Object.entries(patch)) {
    const previous = observed?.[key];
    if (isEmpty(previous) || equals(key, previous, next)) continue;
    const baseKnown = Object.hasOwn(baseFields, key);
    if (baseKnown && equals(key, baseFields[key], previous)) continue;
    entries.push({ field: key, previous, next, baseKnown });
  }
  return entries;
}

const serialize = (value) => (value === undefined ? null : JSON.stringify(value));

const parseValue = (raw) => {
  if (raw == null || raw === '') return null;
  try { return JSON.parse(raw); } catch { return raw; }
};

/** Forme d'une entrée pour l'écran admin et la restauration. */
export function archiveEntryFromRecord(record) {
  const f = record?.fields ?? record ?? {};
  return {
    id: String(f.uuid_source ?? ''),
    rowId: record?.id ?? f.Id ?? null,
    archivedAt: f.archived_at ?? null,
    source: f.source ?? '',
    tableId: f.table_id ?? '',
    recordId: f.record_id ?? '',
    dossierId: f.dossier_id ?? null,
    beneficiaryId: f.beneficiaire_id ?? null,
    field: f.field_name ?? '',
    previous: parseValue(f.previous_value),
    next: parseValue(f.next_value),
    baseKnown: Boolean(f.base_known),
    writeId: f.write_id ?? null,
    actor: f.actor ?? null,
    restoredAt: f.restored_at ?? null,
  };
}

/**
 * enabled=false : aucune lecture ni écriture (comportement actuel).
 * enabled=true : chaque entrée est écrite avant de rendre la main ; une table
 * absente ou une écriture refusée lève SyncArchiveUnavailableError.
 */
export function createSyncArchive({ enabled = false, findTableId, createRecord,
  queryAll = null, updateRecord = null,
  now = () => new Date().toISOString(), newId = randomUUID }) {
  let tableId = null;
  const requireTable = async () => {
    tableId ??= await findTableId();
    if (!tableId) throw new Error(`Table ${SYNC_ARCHIVE_TABLE_NAME} introuvable`);
    return tableId;
  };
  return {
    enabled: Boolean(enabled),
    /** Entrées les plus récentes, éventuellement pour un bénéficiaire. */
    async list({ limit = 100, beneficiaryId = null } = {}) {
      const id = await requireTable();
      const safe = beneficiaryId == null ? null : String(beneficiaryId).replace(/[^\w:.-]/g, '');
      const records = await queryAll(id, {
        ...(safe ? { where: `(beneficiaire_id,eq,${safe})` } : {}),
        sort: '-archived_at',
      });
      return records.slice(0, Math.max(1, Math.min(500, Number(limit) || 100)))
        .map(archiveEntryFromRecord);
    },
    async get(entryId) {
      const id = await requireTable();
      const safe = String(entryId).replace(/[^0-9a-f-]/gi, '');
      if (!safe) return null;
      const records = await queryAll(id, { where: `(uuid_source,eq,${safe})` });
      return records.length === 1 ? archiveEntryFromRecord(records[0]) : null;
    },
    async markRestored(entry) {
      const id = await requireTable();
      await updateRecord(id, entry.rowId, { restored_at: now() });
    },
    async record(entries, { source, tableId: archivedTableId, recordId, dossierId = null,
      beneficiaryId = null, writeId = null, actor = null } = {}) {
      if (!enabled || !entries?.length) return 0;
      try {
        await requireTable();
        const archivedAt = now();
        for (const entry of entries) {
          await createRecord(tableId, {
            uuid_source: newId(),
            archived_at: archivedAt,
            source: String(source || ''),
            table_id: String(archivedTableId ?? ''),
            record_id: String(recordId ?? ''),
            dossier_id: dossierId == null ? null : String(dossierId),
            beneficiaire_id: beneficiaryId == null ? null : String(beneficiaryId),
            field_name: entry.field,
            previous_value: serialize(entry.previous),
            next_value: serialize(entry.next),
            base_known: Boolean(entry.baseKnown),
            write_id: writeId == null ? null : String(writeId),
            actor: actor == null ? null : String(actor),
          });
        }
        return entries.length;
      } catch (cause) {
        tableId = null;
        throw new SyncArchiveUnavailableError(cause);
      }
    },
  };
}
