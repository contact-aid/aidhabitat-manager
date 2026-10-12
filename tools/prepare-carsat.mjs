#!/usr/bin/env node
// Offline preparation only: no dotenv, credentials, network or production adapter.
import { createHash } from 'node:crypto';
import { readFile, writeFile, open, rename, unlink } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const normalize = value => String(value ?? '').normalize('NFKD').replace(/[\u0300-\u036f]/g, '').trim().replace(/\s+/g, ' ').toUpperCase();
const canonical = records => records.map(({ id, fields }) => ({ id: String(id), fields: Object.fromEntries(Object.entries(fields).sort(([a],[b]) => a.localeCompare(b))) })).sort((a,b) => a.id.localeCompare(b.id));
const fingerprint = records => createHash('sha256').update(JSON.stringify(canonical(records))).digest('hex');
function validate(fixture) {
  if (fixture?.environment !== 'synthetic' || fixture?.table !== 'Caisses_de_retraite' || !Array.isArray(fixture.records)) throw new Error('Only a synthetic Caisses_de_retraite fixture is accepted');
  const ids = new Set();
  for (const row of fixture.records) {
    if (!/^\d+$/.test(String(row.id)) || !row.fields || typeof row.fields.nom !== 'string' || ids.has(String(row.id))) throw new Error('Invalid reference record or duplicate ID');
    ids.add(String(row.id));
  }
  const matches = fixture.records.filter(row => normalize(row.fields.nom) === 'CARSAT');
  if (matches.length > 1) throw new Error('Duplicate CARSAT records: manual review required');
  if (!matches.length && fixture.records.some(row => /^CARSAT\b/.test(normalize(row.fields.nom)))) throw new Error('Regional CARSAT reference exists: manual review required');
  return matches[0];
}
export function planCarsat(fixture) {
  const existing = validate(fixture);
  return { schemaVersion: 1, environment: 'synthetic', table: fixture.table, expectedFingerprint: fingerprint(fixture.records), action: existing ? 'noop' : 'create', fields: { nom: 'CARSAT' }, existingId: existing ? String(existing.id) : null };
}
export function applyCarsat(fixture, approvedPlan) {
  const current = planCarsat(fixture);
  if (approvedPlan?.schemaVersion !== 1 || approvedPlan.environment !== 'synthetic' || approvedPlan.table !== 'Caisses_de_retraite' || !['create','noop'].includes(approvedPlan.action) || JSON.stringify(approvedPlan.fields) !== JSON.stringify({ nom: 'CARSAT' })) throw new Error('Invalid CARSAT plan');
  // A replay is harmless even if another approved run already inserted CARSAT.
  if (current.action === 'noop') return { fixture, created: false, id: current.existingId };
  if (approvedPlan.action !== 'create' || approvedPlan.expectedFingerprint !== current.expectedFingerprint) throw new Error('Reference changed: generate and review a new plan');
  const id = String(Math.max(0, ...fixture.records.map(row => Number(row.id))) + 1);
  const next = { ...fixture, records: [...fixture.records, { id, fields: { nom: 'CARSAT' } }] };
  validate(next);
  return { fixture: next, created: true, id };
}
async function main(args) {
  const option = key => args[args.indexOf(key) + 1];
  if (!['plan','apply'].includes(args[0]) || !args.includes('--fixture') || args.some(arg => /https?:\/\//i.test(arg))) throw new Error('Usage: prepare-carsat.mjs plan --fixture <synthetic.json> | apply --fixture <synthetic.json> --plan <reviewed-plan.json>');
  const file = path.resolve(option('--fixture'));
  if (args[0] === 'plan') {
    console.log(JSON.stringify(planCarsat(JSON.parse(await readFile(file,'utf8'))), null, 2));
    return;
  }
  if (!args.includes('--plan')) throw new Error('A reviewed --plan is required');
  const lockFile = `${file}.carsat.lock`;
  const lock = await open(lockFile,'wx',0o600);
  const temporary = `${file}.carsat-${process.pid}.tmp`;
  try {
    const fixture = JSON.parse(await readFile(file,'utf8'));
    const plan = JSON.parse(await readFile(path.resolve(option('--plan')),'utf8'));
    const result = applyCarsat(fixture,plan);
    if (result.created) {
      await writeFile(temporary, JSON.stringify(result.fixture,null,2)+'\n',{flag:'wx',mode:0o600});
      await rename(temporary,file);
    }
    console.log(JSON.stringify({ created: result.created, id: result.id, planAfter: planCarsat(JSON.parse(await readFile(file,'utf8'))) }));
  } finally {
    await lock.close(); await unlink(lockFile); await unlink(temporary).catch(error => { if(error.code!=='ENOENT')throw error; });
  }
}
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main(process.argv.slice(2)).catch(error => { console.error(error.message); process.exitCode=1; });
