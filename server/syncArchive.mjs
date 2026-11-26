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

/**
 * enabled=false : aucune lecture ni écriture (comportement actuel).
 * enabled=true : chaque entrée est écrite avant de rendre la main ; une table
 * absente ou une écriture refusée lève SyncArchiveUnavailableError.
 */
export function createSyncArchive({ enabled = false, findTableId, createRecord,
  now = () => new Date().toISOString(), newId = randomUUID }) {
  let tableId = null;
  return {
    enabled: Boolean(enabled),
    async record(entries, { source, tableId: archivedTableId, recordId, dossierId = null,
      writeId = null, actor = null } = {}) {
      if (!enabled || !entries?.length) return 0;
      try {
        tableId ??= await findTableId();
        if (!tableId) throw new Error(`Table ${SYNC_ARCHIVE_TABLE_NAME} introuvable`);
        const archivedAt = now();
        for (const entry of entries) {
          await createRecord(tableId, {
            uuid_source: newId(),
            archived_at: archivedAt,
            source: String(source || ''),
            table_id: String(archivedTableId ?? ''),
            record_id: String(recordId ?? ''),
            dossier_id: dossierId == null ? null : String(dossierId),
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
