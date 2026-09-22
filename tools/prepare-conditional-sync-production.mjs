#!/usr/bin/env node
// Prepare the seven production tables for conditional synchronization.
// Dry-run by default. Applying requires the documented base, an explicit
// restoration proof argument and AIDHABITAT_PRODUCTION_MIGRATION=1.

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local', quiet: true });

export const PRODUCTION_BASE = 'pskgbjythubfzv9';
export const RESTORE_PROOF = 'apps_restore_test_20260922';
export const PRODUCTION_TABLES = [
  { key: 'beneficiaires', id: 'muvp56d5i9z2qbe', child: false },
  { key: 'logements', id: 'mgdpvdrnzyy6n4k', child: false },
  { key: 'dossiers', id: 'mez74y7ndoej30p', child: false },
  { key: 'contexte_de_vie', id: 'mjyj2lz4wfs5pd5', child: true },
  { key: 'mesures_anthropometriques', id: 'mbaj91z97utreco', child: true },
  { key: 'observations', id: 'mbkuomk0aazes1c', child: true },
  { key: 'diagnostic_sanitaires', id: 'mdukulxcd18ae3o', child: true },
];

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function parseArgs(args, env = process.env) {
  const allowed = new Set(['--apply', `--base=${PRODUCTION_BASE}`, `--backup-restored=${RESTORE_PROOF}`]);
  assert.ok(args.every(arg => allowed.has(arg)), 'Unknown production migration argument');
  assert.ok(args.includes(`--base=${PRODUCTION_BASE}`), 'Pass the production base explicitly');
  const apply = args.includes('--apply');
  if (apply) {
    assert.equal(env.AIDHABITAT_PRODUCTION_MIGRATION, '1', 'Set AIDHABITAT_PRODUCTION_MIGRATION=1');
    assert.ok(args.includes(`--backup-restored=${RESTORE_PROOF}`), 'Pass the verified restoration proof');
  }
  return { apply };
}

async function readRows(request, table, revisionColumn) {
  const rows = [];
  for (let offset = 0; ; offset += 100) {
    assert.ok(offset < 100000, 'Production scan exceeded its safety limit');
    const fields = ['Id', ...(revisionColumn ? ['app_sync_revision'] : []), ...(table.child ? ['dossier_id'] : [])];
    const query = new URLSearchParams({ limit: '100', offset: String(offset), fields: fields.join(','), sort: 'Id' });
    const page = await request('GET', `/api/v2/tables/${table.id}/records?${query}`);
    assert.ok(Array.isArray(page.list) && page.list.length <= 100, `Invalid page for ${table.key}`);
    rows.push(...page.list);
    if (page.list.length < 100) return rows;
  }
}

function childIntegrity(rows) {
  const ids = new Set();
  let duplicates = 0;
  let missingDossiers = 0;
  for (const row of rows) {
    const dossier = String(row.dossier_id ?? '').trim();
    if (!dossier) missingDossiers++;
    else if (ids.has(dossier)) duplicates++;
    else ids.add(dossier);
  }
  return { duplicates, missingDossiers };
}

export async function prepareProduction({ apply, request }) {
  const report = [];
  for (const table of PRODUCTION_TABLES) {
    let schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
    assert.equal(schema.id, table.id);
    assert.equal(schema.base_id, PRODUCTION_BASE);
    let revision = (schema.columns || []).find(column => column.title === 'app_sync_revision');
    if (revision) assert.equal(revision.uidt, 'SingleLineText');

    let rows = await readRows(request, table, Boolean(revision));
    const integrity = table.child ? childIntegrity(rows) : {};
    if (table.child) {
      assert.equal(integrity.duplicates, 0, `${table.key} still has duplicate dossier_id values`);
      assert.equal(integrity.missingDossiers, 0, `${table.key} still has missing dossier_id values`);
    }

    if (!revision && apply) {
      await request('POST', `/api/v2/meta/tables/${table.id}/columns`, {
        title: 'app_sync_revision', column_name: 'app_sync_revision',
        uidt: 'SingleLineText', dt: 'character varying',
      });
      schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
      revision = (schema.columns || []).find(column => column.title === 'app_sync_revision');
      assert.equal(revision?.uidt, 'SingleLineText', `Revision column creation failed for ${table.key}`);
      rows = await readRows(request, table, true);
    }

    const invalid = revision ? rows.filter(row => !uuid.test(String(row.app_sync_revision || ''))) : rows;
    if (apply && invalid.length) {
      for (let index = 0; index < invalid.length; index += 100) {
        await request('PATCH', `/api/v2/tables/${table.id}/records`,
          invalid.slice(index, index + 100).map(row => ({ Id: Number(row.Id), app_sync_revision: randomUUID() })));
      }
    }
    report.push({ table: table.key, id: table.id, records: rows.length,
      revisionColumn: Boolean(revision), revisionsToBackfill: invalid.length, ...integrity });
  }

  if (apply) {
    for (const table of PRODUCTION_TABLES) {
      const schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
      const revision = (schema.columns || []).find(column => column.title === 'app_sync_revision');
      assert.equal(revision?.uidt, 'SingleLineText', `Revision verification failed for ${table.key}`);
      const rows = await readRows(request, table, true);
      assert.ok(rows.every(row => uuid.test(String(row.app_sync_revision || ''))), `Revision backfill failed for ${table.key}`);
      if (table.child) assert.deepEqual(childIntegrity(rows), { duplicates: 0, missingDossiers: 0 });
    }
  }
  return { mode: apply ? 'applied-and-verified' : 'dry-run', baseId: PRODUCTION_BASE,
    backupRestoreProof: apply ? RESTORE_PROOF : null, tables: report,
    uniqueIndexesCreated: false, activationApproved: false };
}

async function createRequest() {
  const root = new URL(process.env.NOCODB_API_URL);
  assert.equal(root.protocol, 'https:');
  const token = process.env.NOCODB_API_TOKEN;
  assert.ok(token, 'NOCODB_API_TOKEN is required');
  return async (method, path, body) => {
    const response = await fetch(new URL(path, root.origin), {
      method,
      headers: { 'xc-token': token, Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path} failed with HTTP ${response.status}`);
    return text ? JSON.parse(text) : null;
  };
}

async function main(args) {
  const { apply } = parseArgs(args);
  console.log(JSON.stringify(await prepareProduction({ apply, request: await createRequest() }), null, 2));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(error => {
    console.error(`Production preparation stopped: ${error.message}`);
    process.exitCode = 1;
  });
}
