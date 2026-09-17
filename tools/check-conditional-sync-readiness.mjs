import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { createProbeRestRequest } from './probe-nocodb-conditional-write.mjs';
import { validateConditionalSchema } from '../server/nocodbConditionalWrite.mjs';

export const SYNC_BASE = 'pskgbjythubfzv9';
const tables = [
  { name: 'beneficiaires', id: 'muvp56d5i9z2qbe' },
  { name: 'logements', id: 'mgdpvdrnzyy6n4k' },
  { name: 'dossiers', id: 'mez74y7ndoej30p' },
  { name: 'contexte_de_vie', id: 'mjyj2lz4wfs5pd5', child: true },
  { name: 'mesures_anthropometriques', id: 'mbaj91z97utreco', child: true },
  { name: 'observations_synthese', id: 'mbkuomk0aazes1c', child: true },
  { name: 'diagnostic_sanitaires', id: 'mdukulxcd18ae3o', child: true },
];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// Readiness only: no table creation, record update, secret output or activation.
export async function checkConditionalSyncReadiness({ baseId, check = false, request }) {
  assert.equal(baseId, SYNC_BASE, 'Pass the documented application base explicitly');
  if (!check) return { mode: 'dry-run', baseId, writes: 0, tables };
  const results = [];
  for (const table of tables) {
    const schema = await request({ method: 'GET', path: `/api/v2/meta/tables/${table.id}` });
    assert.equal(schema.id, table.id);
    assert.equal(schema.base_id, baseId);
    try {
      validateConditionalSchema(schema, { tableId: table.id, baseId });
    } catch (e) {
      results.push({ ...table, ready: false, reason: e.code });
      continue;
    }
    let checkedRows = 0;
    let invalidRevisions = 0;
    let duplicateDossiers = 0;
    let missingDossiers = 0;
    const dossierIds = new Set();
    const seen = new Set();
    for (let offset = 0; ; offset += 100) {
      assert.ok(offset < 100000, 'Readiness scan exceeded its safety limit');
      const query = new URLSearchParams({ fields: `Id,app_sync_revision${table.child ? ',dossier_id' : ''}`, limit: '100', offset: String(offset), sort: 'Id' });
      const result = await request({ method: 'GET', path: `/api/v2/tables/${table.id}/records?${query}` });
      assert.ok(Array.isArray(result.list) && result.list.length <= 100);
      for (const row of result.list) {
        assert.ok(Number.isSafeInteger(Number(row.Id)) && Number(row.Id) > 0 && !seen.has(Number(row.Id)), 'Readiness pagination is inconsistent');
        seen.add(Number(row.Id));
        checkedRows++;
        if (typeof row.app_sync_revision !== 'string' || !uuid.test(row.app_sync_revision)) invalidRevisions++;
        if (table.child) {
          const id = String(row.dossier_id ?? '').trim();
          if (!id) missingDossiers++;
          else if (dossierIds.has(id)) duplicateDossiers++;
          else dossierIds.add(id);
        }
      }
      if (result.list.length < 100) break;
    }
    results.push({ ...table, ready: invalidRevisions === 0 && duplicateDossiers === 0 && missingDossiers === 0,
      checkedRows, invalidRevisions, ...(table.child ? { duplicateDossiers, missingDossiers } : {}) });
  }
  return { mode: 'checked', baseId, writes: 0, tables: results,
    schemaAndRevisionsReady: results.every(r => r.ready),
    activationApproved: false,
    remainingChecks: ['database-unique-child-dossier-indexes', 'all-writers-covered', 'old-client-cutover', 'conflict-resolution-all-entities', 'device-offline-recipe'],
  };
}

async function main(args) {
  assert.ok(args.every(a => a === '--check' || a === `--base=${SYNC_BASE}`));
  assert.ok(args.includes(`--base=${SYNC_BASE}`));
  const check = args.includes('--check');
  const report = await checkConditionalSyncReadiness({ baseId: SYNC_BASE, check,
    request: check ? await createProbeRestRequest() : undefined });
  console.log(JSON.stringify(report, null, 2));
  if (check && !report.schemaAndRevisionsReady) process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(e => { console.error(`Readiness stopped: ${e.message}`); process.exitCode = 1; });
}
