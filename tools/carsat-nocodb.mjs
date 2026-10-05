#!/usr/bin/env node
// Controlled, additive operation on the real NocoDB principal-funds table.
import { createHash, randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const PRODUCTION_BASE = 'pskgbjythubfzv9';
export const PRODUCTION_TABLE = 'mxmsm320nnljdmm';
const TABLE_TITLE = 'Caisses_de_retraite';
const normalize = value => String(value ?? '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '').trim().replace(/\s+/g, ' ').toUpperCase();
const sha = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const canonical = rows => rows.map(row => ({ ...row })).sort((a, b) => String(a.Id).localeCompare(String(b.Id)));

export function inspectFunds(rows) {
  if (!Array.isArray(rows)) throw Error('Invalid funds response');
  const ids = new Set();
  for (const row of rows) {
    const id = String(row?.Id ?? '');
    if (!/^\d+$/.test(id) || ids.has(id) || typeof row.nom !== 'string') throw Error('Invalid or duplicate principal-fund record');
    ids.add(id);
  }
  const exact = rows.filter(row => normalize(row.nom) === 'CARSAT');
  if (exact.length > 1) throw Error('Duplicate CARSAT rows: manual review required');
  if (!exact.length && rows.some(row => /^CARSAT\b/.test(normalize(row.nom)))) throw Error('Regional CARSAT row: manual review required');
  return { exact: exact[0] ?? null, overlapping: rows.filter(row => normalize(row.nom).includes('CARSAT') && !exact.includes(row)).map(row => ({ id: String(row.Id), nom: row.nom })) };
}

export function makePlan({ environment, baseId, tableId, rows, operationId = randomUUID() }) {
  if (!['staging', 'production'].includes(environment) || !baseId || !tableId) throw Error('Explicit target environment, base and table required');
  if ((environment === 'production') !== (baseId === PRODUCTION_BASE)) throw Error('Environment/base mismatch');
  if (environment === 'production' && tableId !== PRODUCTION_TABLE) throw Error('Production table mismatch');
  const result = inspectFunds(rows);
  return {
    schemaVersion: 1, environment, baseId, tableId, tableTitle: TABLE_TITLE,
    action: result.exact ? 'noop' : 'create', fields: { nom: 'CARSAT' },
    existingId: result.exact ? String(result.exact.Id) : null,
    operationId, countBefore: rows.length, beforeSha256: sha(canonical(rows)),
    overlappingLabels: result.overlapping,
  };
}

export function createNocodbClient({ apiUrl, token, fetchImpl = fetch }) {
  if (!apiUrl || !token || !/^https:\/\//.test(apiUrl)) throw Error('HTTPS NOCODB_API_URL and NOCODB_API_TOKEN required');
  const root = apiUrl.replace(/\/+$/, '');
  const request = async (route, method = 'GET', body) => {
    const response = await fetchImpl(`${root}${route}`, {
      method, headers: { 'xc-token': token, 'Content-Type': 'application/json' },
      ...(body ? { body: JSON.stringify(body) } : {}), signal: AbortSignal.timeout(30000),
    });
    if (!response.ok) throw Error(`NocoDB ${method} HTTP ${response.status}`);
    return response.json();
  };
  return {
    async read(baseId) {
      const payload = await request(`/api/v2/meta/bases/${encodeURIComponent(baseId)}/tables`);
      const matches = (payload.list ?? []).filter(table => table.title === TABLE_TITLE);
      if (matches.length !== 1) throw Error('Principal-funds table missing or ambiguous');
      const tableId = matches[0].id;
      if (baseId === PRODUCTION_BASE && tableId !== PRODUCTION_TABLE) throw Error('Production table ID changed');
      const meta = await request(`/api/v2/meta/tables/${encodeURIComponent(tableId)}`);
      if (meta.id !== tableId || meta.base_id !== baseId || meta.title !== TABLE_TITLE ||
          !['Id', 'nom', 'uuid_source'].every(title => (meta.columns ?? []).some(col => col.title === title))) {
        throw Error('Principal-funds schema mismatch');
      }
      const rows = [];
      for (let offset = 0; ; offset += 100) {
        const page = await request(`/api/v2/tables/${encodeURIComponent(tableId)}/records?limit=100&offset=${offset}`);
        if (!Array.isArray(page.list)) throw Error('Invalid records page');
        rows.push(...page.list);
        if (page.pageInfo?.isLastPage || page.list.length < 100) break;
      }
      inspectFunds(rows);
      return { tableId, rows };
    },
    create: (tableId, operationId) => request(`/api/v2/tables/${encodeURIComponent(tableId)}/records`, 'POST', { nom: 'CARSAT', uuid_source: operationId }),
  };
}

export async function applyPlan(client, plan, { environment, baseId, exclusiveWindowConfirmed = false } = {}) {
  if (!exclusiveWindowConfirmed) throw Error('Exclusive creation window must be confirmed');
  if (plan?.schemaVersion !== 1 || plan.environment !== environment || plan.baseId !== baseId ||
      plan.tableTitle !== TABLE_TITLE || !['create', 'noop'].includes(plan.action) ||
      JSON.stringify(plan.fields) !== JSON.stringify({ nom: 'CARSAT' }) ||
      !/^[0-9a-f-]{36}$/i.test(plan.operationId ?? '')) throw Error('Invalid or mismatched reviewed plan');
  const before = await client.read(baseId);
  const current = makePlan({ environment, baseId, tableId: before.tableId, rows: before.rows, operationId: plan.operationId });
  if (plan.tableId !== current.tableId) throw Error('Table changed');
  if (current.action === 'noop') {
    if (plan.action === 'noop' && plan.existingId === current.existingId) return { created: false, id: current.existingId, verified: true };
    const row = before.rows.find(item => String(item.Id) === current.existingId);
    if (plan.action === 'create' && row?.uuid_source === plan.operationId) return { created: false, id: current.existingId, verified: true, replay: true };
    throw Error('CARSAT appeared since planning: manual review required');
  }
  if (plan.action !== 'create' || plan.beforeSha256 !== current.beforeSha256 || plan.countBefore !== current.countBefore) {
    throw Error('Reference changed: regenerate and review the plan');
  }
  let postError;
  try { await client.create(before.tableId, plan.operationId); } catch (error) { postError = error; }
  const after = await client.read(baseId);
  const match = inspectFunds(after.rows).exact;
  if (!match || match.uuid_source !== plan.operationId ||
      sha(canonical(after.rows.filter(row => String(row.Id) !== String(match.Id)))) !== current.beforeSha256 ||
      after.rows.length !== before.rows.length + 1) {
    throw Error(`Creation not verified${postError ? ' after uncertain response' : ''}: manual review required`);
  }
  return { created: true, id: String(match.Id), verified: true, recoveredAfterUncertainResponse: Boolean(postError) };
}

async function main(args) {
  const mode = args[0];
  const value = flag => args[args.indexOf(flag) + 1];
  const environment = value('--environment');
  const baseId = value('--base');
  if (!['plan', 'apply'].includes(mode) || !['staging', 'production'].includes(environment) || !baseId ||
      (environment === 'production') !== (baseId === PRODUCTION_BASE)) {
    throw Error('Usage: carsat-nocodb.mjs plan|apply --environment staging|production --base BASE [--plan FILE --apply --exclusive-window-confirmed]');
  }
  const client = createNocodbClient({ apiUrl: process.env.NOCODB_API_URL, token: process.env.NOCODB_API_TOKEN });
  if (mode === 'plan') {
    const snapshot = await client.read(baseId);
    const plan = makePlan({ environment, baseId, ...snapshot });
    if (environment === 'production' && !args.includes('--snapshot')) throw Error('Production plan requires --snapshot FILE');
    if (args.includes('--snapshot')) {
      await writeFile(path.resolve(value('--snapshot')), JSON.stringify({ environment, baseId, tableId: snapshot.tableId, rows: snapshot.rows }, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    }
    console.log(JSON.stringify(plan, null, 2));
    return;
  }
  if (!args.includes('--plan')) throw Error('Reviewed --plan FILE required');
  const plan = JSON.parse(await readFile(path.resolve(value('--plan')), 'utf8'));
  if (!args.includes('--apply')) {
    const snapshot = await client.read(baseId);
    const current = makePlan({ environment, baseId, ...snapshot, operationId: plan.operationId });
    console.log(JSON.stringify({ dryRun: true, plan, current }, null, 2));
    return;
  }
  if (process.env.CARSAT_ALLOW_APPLY !== '1' || !args.includes('--exclusive-window-confirmed')) {
    throw Error('Apply requires CARSAT_ALLOW_APPLY=1 and --exclusive-window-confirmed');
  }
  if (environment === 'production') {
    if (!args.includes('--staging-verified') || !args.includes('--snapshot')) throw Error('Production apply requires --staging-verified and --snapshot FILE');
    const saved = JSON.parse(await readFile(path.resolve(value('--snapshot')), 'utf8'));
    if (saved.environment !== environment || saved.baseId !== baseId || saved.tableId !== plan.tableId ||
        !Array.isArray(saved.rows) || sha(canonical(saved.rows)) !== plan.beforeSha256) {
      throw Error('Production snapshot does not match reviewed plan');
    }
  }
  console.log(JSON.stringify(await applyPlan(client, plan, { environment, baseId, exclusiveWindowConfirmed: true })));
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode = 1; });
}
