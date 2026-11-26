#!/usr/bin/env node
// Vérifie un dump `tools/backup-nocodb.mjs` en le lisant petit à petit.
//
// Usage :
//   node tools/verify-nocodb-backup-stream.mjs backups/aidhabitat-....json.gz
//
// Même contrôles que verify-nocodb-backup.mjs (gzip lisible, JSON valide,
// tables critiques présentes et non vides, chunks reliés à un document),
// mais sans jamais charger le fichier entier en mémoire : chaque record est
// extrait et analysé seul. Nécessaire dès que la base décompressée dépasse
// la taille maximale d'une chaîne JavaScript (environ 512 Mo).
//
// Ne restaure rien et ne contacte pas NocoDB.

import { createReadStream } from 'node:fs';
import { createGunzip } from 'node:zlib';
import path from 'node:path';
import process from 'node:process';
import {
  REQUIRED_BACKUP_TABLES,
  REQUIRED_NON_EMPTY_BACKUP_TABLES,
  normalizeTableName,
} from './nocodbBackupLib.mjs';

const value = (record, key) => (record?.[key] == null ? '' : String(record[key]).trim());

/**
 * Parcourt le flux texte du dump. Structure attendue :
 *   { ...en-tête, "tables": [ { ...en-tête table, "records": [ {record}, ... ] }, ... ] }
 * Profondeurs : 1 racine, 2 tableau tables, 3 table, 4 tableau records, 5 record.
 */
export async function scanBackupStream(textStream, { onRoot, onTable, onRecord, onTableEnd }) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  let rootHeader = '';
  let rootDone = false;
  let tableHeader = null;
  let inRecords = false;
  let recordParts = null;
  let recordStart = -1;
  let totalChars = 0;

  for await (const chunk of textStream) {
    totalChars += chunk.length;
    let headerStart = !rootDone ? 0 : tableHeader !== null && !inRecords ? 0 : -1;
    for (let i = 0; i < chunk.length; i++) {
      const c = chunk[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (c === '\\') escaped = true;
        else if (c === '"') inString = false;
        continue;
      }
      if (c === '"') { inString = true; continue; }
      if (c === '{' || c === '[') {
        depth += 1;
        if (!rootDone && depth === 2) {
          rootHeader += chunk.slice(headerStart, i + 1);
          onRoot(JSON.parse(`${rootHeader}]}`));
          rootDone = true;
          headerStart = -1;
        } else if (depth === 3 && c === '{') {
          tableHeader = '';
          headerStart = i;
        } else if (depth === 4 && c === '[' && tableHeader !== null && !inRecords) {
          const text = tableHeader + chunk.slice(headerStart, i + 1);
          if (/"records"\s*:\s*\[$/.test(text)) {
            onTable(JSON.parse(`${text}]}`));
            tableHeader = null;
            inRecords = true;
            headerStart = -1;
          }
        } else if (depth === 5 && inRecords && c === '{') {
          recordParts = [];
          recordStart = i;
        }
      } else if (c === '}' || c === ']') {
        if (depth === 5 && inRecords && c === '}' && recordParts) {
          recordParts.push(chunk.slice(recordStart, i + 1));
          onRecord(JSON.parse(recordParts.join('')));
          recordParts = null;
          recordStart = -1;
        } else if (depth === 4 && inRecords && c === ']') {
          inRecords = false;
        } else if (depth === 3 && c === '}') {
          onTableEnd();
        }
        depth -= 1;
        if (depth < 0) throw new Error('structure JSON invalide (fermeture en trop)');
      }
    }
    if (headerStart >= 0) {
      if (!rootDone) rootHeader += chunk.slice(headerStart);
      else if (tableHeader !== null) tableHeader += chunk.slice(headerStart);
    }
    if (recordParts) {
      recordParts.push(chunk.slice(recordStart));
      recordStart = 0;
    }
  }
  if (depth !== 0 || inString || !rootDone) {
    throw new Error('fichier tronqué ou JSON incomplet');
  }
  return { totalChars };
}

export async function verifyBackupStream(file) {
  const failures = [];
  const warnings = [];
  let root = null;
  const tables = new Map();
  let current = null;
  const documentIds = new Set();
  const chunkDocumentIds = [];

  const textStream = createReadStream(path.resolve(file))
    .pipe(createGunzip())
    .setEncoding('utf8');

  const { totalChars } = await scanBackupStream(textStream, {
    onRoot: (header) => { root = header; },
    onTable: (header) => {
      const name = normalizeTableName(header?.name);
      if (!name) failures.push('table sans nom');
      if (!Array.isArray(header?.fields)) warnings.push(`schema absent ou invalide pour ${name}`);
      current = { name, records: 0 };
      tables.set(name, current);
    },
    onRecord: (record) => {
      if (!current) throw new Error('record hors table');
      current.records += 1;
      if (current.name === 'mobile_documents') {
        const id = value(record, 'uuid_source');
        if (id) documentIds.add(id);
      } else if (current.name === 'mobile_document_chunks') {
        chunkDocumentIds.push(value(record, 'document_uuid_source'));
      }
    },
    onTableEnd: () => { current = null; },
  });

  if (!root?.baseId) failures.push('baseId manquant');
  if (tables.size === 0) failures.push('aucune table dans le backup');
  for (const required of REQUIRED_BACKUP_TABLES) {
    const table = tables.get(required);
    if (!table) failures.push(`table critique absente: ${required}`);
    else if (REQUIRED_NON_EMPTY_BACKUP_TABLES.has(required) && table.records === 0) {
      failures.push(`table critique vide: ${required}`);
    }
  }
  let orphanChunks = 0;
  for (const id of chunkDocumentIds) {
    if (!id) orphanChunks += 1;
    else if (!id.startsWith('upload_') && !documentIds.has(id)) orphanChunks += 1;
  }
  if (orphanChunks > 0) {
    warnings.push(`${orphanChunks} chunk(s) document sans mobile_document correspondant`);
  }

  const summary = {
    baseId: root?.baseId ?? null,
    createdAt: root?.createdAt ?? null,
    uncompressedMB: Math.round(totalChars / 1024 / 1024),
    tables: tables.size,
    records: [...tables.values()].reduce((sum, t) => sum + t.records, 0),
    perTable: Object.fromEntries([...tables.values()].map((t) => [t.name, t.records])),
    orphanChunks,
  };
  return { ok: failures.length === 0, failures, warnings, summary };
}

const isDirect = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (isDirect) {
  const file = process.argv[2];
  if (!file) {
    console.error('Usage: node tools/verify-nocodb-backup-stream.mjs <backup.json.gz>');
    process.exit(1);
  }
  try {
    const result = await verifyBackupStream(file);
    for (const message of result.warnings) console.warn(`[verify-backup] attention: ${message}`);
    if (!result.ok) {
      console.error(`[verify-backup] ÉCHEC: ${result.failures.join(' ; ')}`);
      process.exit(1);
    }
    console.log('[verify-backup] OK');
    console.log(JSON.stringify(result.summary, null, 2));
  } catch (error) {
    console.error(`[verify-backup] ÉCHEC: lecture/parsing impossible: ${error.message}`);
    process.exit(1);
  }
}
