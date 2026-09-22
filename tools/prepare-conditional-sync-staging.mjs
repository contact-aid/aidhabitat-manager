#!/usr/bin/env node
// Prepare the seven application tables for conditional synchronization.
// Hard-limited to the documented staging base; dry-run unless --apply plus
// AIDHABITAT_STAGING_MIGRATION=1 are both supplied.

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import dotenv from 'dotenv';

dotenv.config({ path: '.env.local', quiet: true });

export const STAGING_BASE = 'p7jzofcton1tabh';
export const REQUIRED_TABLES = [
  { key: 'beneficiaires', child: false },
  { key: 'logements', child: false },
  { key: 'dossiers', child: false },
  { key: 'contexte_de_vie', child: true },
  { key: 'mesures_anthropometriques', child: true },
  { key: 'observations', child: true },
  { key: 'diagnostic_sanitaires', child: true },
];

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const normalize = value => String(value || '').normalize('NFKD')
  .replace(/[\u0300-\u036f]/g, '').replace(/^[^a-z0-9]+/i, '').trim().toLowerCase();

export function buildPlan(tables) {
  const matched = REQUIRED_TABLES.map(required => {
    const candidates = tables.filter(table => normalize(table.title || table.table_name) === required.key);
    assert.equal(candidates.length, 1, `Expected exactly one staging table for ${required.key}`);
    return { ...required, id: candidates[0].id, title: candidates[0].title || candidates[0].table_name };
  });
  return matched;
}

async function main(args) {
  assert.ok(args.every(arg => arg === '--apply' || arg === `--base=${STAGING_BASE}`));
  assert.ok(args.includes(`--base=${STAGING_BASE}`), 'Pass the staging base explicitly');
  const apply = args.includes('--apply');
  if (apply) assert.equal(process.env.AIDHABITAT_STAGING_MIGRATION, '1', 'Set AIDHABITAT_STAGING_MIGRATION=1');

  const root = new URL(process.env.NOCODB_API_URL);
  assert.equal(root.protocol, 'https:');
  const token = process.env.NOCODB_API_TOKEN;
  assert.ok(token);
  const request = async (method, path, body) => {
    const response = await fetch(new URL(path, root.origin), {
      method,
      headers: { 'xc-token': token, Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`${method} ${path} failed with HTTP ${response.status}`);
    return text ? JSON.parse(text) : null;
  };

  const payload = await request('GET', `/api/v2/meta/bases/${STAGING_BASE}/tables`);
  const plan = buildPlan(Array.isArray(payload) ? payload : payload.list || payload.tables || []);
  const report = [];
  for (const table of plan) {
    let schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
    let revision = (schema.columns || []).find(column => column.title === 'app_sync_revision');
    if (!revision && apply) {
      await request('POST', `/api/v2/meta/tables/${table.id}/columns`, {
        title: 'app_sync_revision', column_name: 'app_sync_revision',
        uidt: 'SingleLineText', dt: 'character varying',
      });
      schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
      revision = (schema.columns || []).find(column => column.title === 'app_sync_revision');
    }
    if (revision) assert.equal(revision.uidt, 'SingleLineText');

    const rows = [];
    for (let offset = 0; ; offset += 100) {
      const fields = ['Id', ...(revision ? ['app_sync_revision'] : []), ...(table.child ? ['dossier_id'] : [])];
      const query = new URLSearchParams({ limit: '100', offset: String(offset), fields: fields.join(','), sort: 'Id' });
      const page = await request('GET', `/api/v2/tables/${table.id}/records?${query}`);
      assert.ok(Array.isArray(page.list) && page.list.length <= 100);
      rows.push(...page.list);
      if (page.list.length < 100) break;
    }
    const invalid = rows.filter(row => !uuid.test(String(row.app_sync_revision || '')));
    if (apply && invalid.length) {
      for (let index = 0; index < invalid.length; index += 100) {
        await request('PATCH', `/api/v2/tables/${table.id}/records`, invalid.slice(index, index + 100).map(row => ({ Id: Number(row.Id), app_sync_revision: randomUUID() })));
      }
    }
    const dossierIds = new Set();
    let duplicates = 0;
    let missingDossiers = 0;
    if (table.child) for (const row of rows) {
      const dossier = String(row.dossier_id || '').trim();
      if (!dossier) missingDossiers++;
      else if (dossierIds.has(dossier)) duplicates++;
      else dossierIds.add(dossier);
    }
    report.push({ table: table.key, id: table.id, records: rows.length,
      revisionColumn: Boolean(revision), revisionsToBackfill: invalid.length,
      ...(table.child ? { duplicates, missingDossiers } : {}) });
  }

  if (apply) {
    // Re-run as an independent verification; never infer success from PATCH counts.
    const failed = [];
    for (const table of plan) {
      const schema = await request('GET', `/api/v2/meta/tables/${table.id}`);
      if (!(schema.columns || []).some(column => column.title === 'app_sync_revision' && column.uidt === 'SingleLineText')) failed.push(table.key);
      for (let offset = 0; ; offset += 100) {
        const query = new URLSearchParams({ limit: '100', offset: String(offset), fields: 'Id,app_sync_revision', sort: 'Id' });
        const page = await request('GET', `/api/v2/tables/${table.id}/records?${query}`);
        if (!page.list.every(row => uuid.test(String(row.app_sync_revision || '')))) failed.push(table.key);
        if (page.list.length < 100) break;
      }
    }
    assert.deepEqual([...new Set(failed)], [], 'Staging verification failed');
  }
  console.log(JSON.stringify({ mode: apply ? 'applied-and-verified' : 'dry-run', baseId: STAGING_BASE, tables: report,
    uniqueIndexesCreated: false, activationApproved: false }, null, 2));
}

if (import.meta.url === new URL(process.argv[1], 'file:').href) {
  main(process.argv.slice(2)).catch(error => { console.error(`Staging preparation stopped: ${error.message}`); process.exitCode = 1; });
}
