#!/usr/bin/env node
// Crée la table NocoDB `sync_archive` (étape 1 du plan de synchronisation).
//
// Sans option : lecture seule. Indique si la table existe et ce qui serait créé.
// Avec --apply : crée la table si elle est absente, puis relit son schéma.
// Ne modifie jamais une table existante (même nom) : s'arrête en signalant
// les colonnes manquantes, à traiter à la main.
//
// Variables : NOCODB_API_URL, NOCODB_API_TOKEN, NOCODB_BASE_ID.
// Sur le serveur, dans un conteneur temporaire à l'image de l'API :
//   voir tools/run-in-api-image.sh

import process from 'node:process';
import { SYNC_ARCHIVE_SCHEMA_SPEC } from '../server/syncArchive.mjs';

const apply = process.argv.includes('--apply');
const url = String(process.env.NOCODB_API_URL || '').replace(/\/+$/, '');
const token = String(process.env.NOCODB_API_TOKEN || '');
const baseId = String(process.env.NOCODB_BASE_ID || '');
if (!url || !token || !baseId) {
  console.error('[sync-archive] NOCODB_API_URL, NOCODB_API_TOKEN et NOCODB_BASE_ID sont requis.');
  process.exit(1);
}

const TYPES = {
  SingleLineText: { uidt: 'SingleLineText', dt: 'character varying' },
  LongText: { uidt: 'LongText', dt: 'text' },
  DateTime: { uidt: 'DateTime', dt: 'datetime' },
  Checkbox: { uidt: 'Checkbox', dt: 'boolean' },
};

async function request(method, path, body) {
  const response = await fetch(url + path, {
    method,
    headers: { 'xc-token': token, 'content-type': 'application/json', accept: 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`${method} ${path} : HTTP ${response.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

const listTables = async () => {
  const payload = await request('GET', `/api/v2/meta/bases/${encodeURIComponent(baseId)}/tables`);
  return Array.isArray(payload?.list) ? payload.list : [];
};
const findArchive = async () => (await listTables()).find((t) =>
  String(t?.title || '').trim().toLowerCase() === SYNC_ARCHIVE_SCHEMA_SPEC.tableName.toLowerCase());

const expected = SYNC_ARCHIVE_SCHEMA_SPEC.fields;
const checkColumns = async (table) => {
  const schema = await request('GET', `/api/v2/meta/tables/${encodeURIComponent(table.id)}`);
  const present = new Map((schema?.columns || []).map((c) => [String(c.title), String(c.uidt)]));
  const missing = expected.filter(([name]) => !present.has(name));
  const wrongType = expected.filter(([name, type]) => present.has(name) && present.get(name) !== type);
  return { missing, wrongType };
};

const existing = await findArchive();
if (existing) {
  const { missing, wrongType } = await checkColumns(existing);
  console.log(`[sync-archive] Table « ${existing.title} » déjà présente (id ${existing.id}).`);
  if (!missing.length && !wrongType.length) {
    console.log('[sync-archive] Schéma conforme. Rien à faire.');
    process.exit(0);
  }
  console.error('[sync-archive] Schéma différent, non modifié automatiquement :',
    JSON.stringify({ missing, wrongType }));
  process.exit(2);
}

console.log(`[sync-archive] Table « ${SYNC_ARCHIVE_SCHEMA_SPEC.tableName} » absente.`);
console.log('[sync-archive] Colonnes prévues :', expected.map(([n, t]) => `${n} (${t})`).join(', '));
if (!apply) {
  console.log('[sync-archive] Lecture seule : relancer avec --apply pour la créer.');
  process.exit(0);
}

await request('POST', `/api/v2/meta/bases/${encodeURIComponent(baseId)}/tables`, {
  title: SYNC_ARCHIVE_SCHEMA_SPEC.tableName,
  table_name: SYNC_ARCHIVE_SCHEMA_SPEC.tableName,
  columns: [
    { title: 'Id', column_name: 'id', uidt: 'ID', pk: true, ai: true, rqd: true },
    ...expected.map(([name, type]) => ({ title: name, column_name: name, ...TYPES[type] })),
  ],
});
const created = await findArchive();
if (!created) {
  console.error('[sync-archive] Création annoncée mais table introuvable à la relecture.');
  process.exit(1);
}
const { missing, wrongType } = await checkColumns(created);
if (missing.length || wrongType.length) {
  console.error('[sync-archive] Table créée mais schéma incomplet :', JSON.stringify({ missing, wrongType }));
  process.exit(2);
}
console.log(`[sync-archive] Table créée et vérifiée (id ${created.id}). CREATION OK`);
