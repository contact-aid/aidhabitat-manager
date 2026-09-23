import crypto from 'node:crypto';
import process from 'node:process';

import dotenv from 'dotenv';

import {
  encodeVisitRecommendationsSnapshotItems,
  hashVisitRecommendationsRequest,
} from '../server/visitRecommendationsPublication.mjs';

dotenv.config({ path: '.env.local' });
dotenv.config();

const apply = process.argv.includes('--apply');
const baseId = String(process.env.NOCODB_BASE_ID || '').trim();
const apiToken = String(process.env.NOCODB_API_TOKEN || '').trim();
const authToken = String(process.env.NOCODB_AUTH_TOKEN || '').trim();
const apiRoot = (() => {
  const raw = String(process.env.NOCODB_API_URL || process.env.NOCODB_MCP_URL || '').trim();
  if (!raw) return '';
  const url = new URL(raw);
  let path = url.pathname.replace(/\/+$/, '');
  if (path.includes('/mcp/')) path = path.slice(0, path.indexOf('/mcp/'));
  path = path.replace(/\/api\/v[12].*$/, '');
  return `${url.origin}${path}`;
})();
const authHeader = apiToken ? 'xc-token' : 'xc-auth';
const authValue = apiToken || authToken;

if (!baseId || !apiRoot || !authValue) {
  throw new Error('Configuration NocoDB incomplete');
}

const request = async (method, path, body) => {
  const response = await fetch(`${apiRoot}${path}`, {
    method,
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
      [authHeader]: authValue,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} ${method} ${path}: ${JSON.stringify(payload)}`);
  }
  return payload;
};

const listTables = async () => {
  const payload = await request('GET', `/api/v2/meta/bases/${baseId}/tables`);
  return Array.isArray(payload) ? payload : payload?.list || payload?.tables || [];
};

const listRecords = async (tableId, fields) => {
  const rows = [];
  for (let offset = 0; ; offset += 100) {
    const params = new URLSearchParams({ limit: '100', offset: String(offset), fields: fields.join(',') });
    const payload = await request('GET', `/api/v2/tables/${tableId}/records?${params}`);
    const batch = Array.isArray(payload) ? payload : payload?.list || [];
    rows.push(...batch);
    if (batch.length < 100) break;
  }
  return rows;
};

const value = (input) => input == null ? '' : String(input);
const legacyToItem = (row) => ({
  id: value(row.uuid_source || row.Id),
  wikiItemId: value(row.wiki_item_id),
  wikiTitle: value(row.wiki_title),
  // Historical rows may contain complete base64 images. The snapshot keeps
  // the wiki identity; the API rehydrates the current library image on read.
  wikiImageUrl: /^data:/i.test(value(row.wiki_image_url)) ? '' : value(row.wiki_image_url),
  wikiTag: value(row.wiki_tag),
  wikiDescription: value(row.wiki_description),
  customTitle: value(row.custom_title),
  note: value(row.note),
  createdAt: value(row.created_at || row.updated_at),
  updatedAt: value(row.updated_at || row.created_at),
});

const tables = await listTables();
const byTitle = (title) => tables.find((table) => value(table.title).toLowerCase() === title.toLowerCase());
const legacy = byTitle(process.env.NOCODB_VISIT_RECOMMENDATIONS_TABLE_NAME || 'mobile_visit_recommendations');
const snapshots = byTitle(process.env.NOCODB_VISIT_RECOMMENDATIONS_SNAPSHOT_TABLE_NAME || 'mobile_visit_recommendation_snapshots');
if (!legacy?.id || !snapshots?.id) throw new Error('Tables de preconisations introuvables');

const legacyRows = await listRecords(legacy.id, [
  'Id', 'uuid_source', 'dossier_id', 'wiki_item_id', 'wiki_title',
  'wiki_image_url', 'wiki_tag', 'custom_title', 'note',
  'created_at', 'updated_at',
]);
const snapshotRows = await listRecords(snapshots.id, ['Id', 'dossier_id']);
const existingDossiers = new Set(snapshotRows.map((row) => value(row.dossier_id)));
const groups = new Map();
for (const row of legacyRows) {
  const dossierId = value(row.dossier_id).trim();
  if (!dossierId) throw new Error(`Preconisation ${row.Id} sans dossier_id`);
  if (!groups.has(dossierId)) groups.set(dossierId, []);
  groups.get(dossierId).push(legacyToItem(row));
}

const pending = [...groups.entries()]
  .filter(([dossierId]) => !existingDossiers.has(dossierId))
  .map(([dossierId, items]) => {
    items.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const revision = crypto.randomUUID();
    return {
      dossier_id: dossierId,
      items_json: encodeVisitRecommendationsSnapshotItems(items),
      request_hash: hashVisitRecommendationsRequest({ dossierId, items }),
      app_sync_revision: revision,
      last_write_id: revision,
      updated_at: items.map((item) => item.updatedAt).filter(Boolean).sort().at(-1)
        || new Date().toISOString(),
    };
  });

console.log(JSON.stringify({
  legacyRows: legacyRows.length,
  dossiers: groups.size,
  existingSnapshots: snapshotRows.length,
  snapshotsToCreate: pending.length,
  mode: apply ? 'apply' : 'dry-run',
}, null, 2));

if (apply) {
  for (const row of pending) {
    await request('POST', `/api/v2/tables/${snapshots.id}/records`, row);
  }
  const after = await listRecords(snapshots.id, ['Id', 'dossier_id']);
  if (after.length !== groups.size) {
    throw new Error(`Verification echouee: ${after.length} snapshots pour ${groups.size} dossiers`);
  }
  console.log(`Migration verifiee: ${after.length} snapshots.`);
}
