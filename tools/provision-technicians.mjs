import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { TECHNICIAN_PROFILES } from '../server/technicianProfiles.mjs';

// Explicit remote account provisioning, never part of application startup.
// Passwords are returned only to a local owner-readable file, never to logs.
const apply = process.argv.includes('--apply');
const outputArg = process.argv.find(a => a.startsWith('--output='));
if (apply && !outputArg) throw new Error('--apply requires --output=/absolute/private/file');
const output = outputArg?.slice('--output='.length);
if (output && (!path.isAbsolute(output) || fs.existsSync(output))) throw new Error('Output must be a new absolute path');

async function remote(profiles, apply) {
  const crypto = await import('node:crypto');
  const { buildPasswordCredential } = await import(`${process.cwd()}/server/passwordCredential.mjs`);
  const root = new URL(process.env.NOCODB_API_URL).origin;
  const table = 'mww8mr4ngp3nbxh';
  const request = async (url, body) => {
    const response = await fetch(root + url, { method: body ? 'POST' : 'GET',
      headers: { 'xc-token': process.env.NOCODB_API_TOKEN, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
    if (!response.ok) throw new Error(`NocoDB HTTP ${response.status}`);
    return response.json();
  };
  const schema = await request(`/api/v2/meta/tables/${table}`);
  if (schema.id !== table || schema.base_id !== process.env.NOCODB_BASE_ID) throw new Error('Unexpected account table/base');
  const results = [];
  for (const [email, profile] of Object.entries(profiles)) {
    const entry = { email, displayName: profile.displayName, intendedRole: 'TECHNICIAN' };
    results.push(entry);
    try {
      const query = new URLSearchParams({ where: `(email,eq,${email})`, limit: '2' });
      const existing = await request(`/api/v2/tables/${table}/records?${query}`);
      if (!Array.isArray(existing.list)) throw new Error('Invalid account response');
      if (existing.list.length) { entry.status = 'existing-not-modified'; continue; }
      if (!apply) { entry.status = 'would-create'; continue; }
      const password = `Ah!7${crypto.randomBytes(18).toString('base64url')}`;
      // Keep the generated password even if a POST response is lost.
      entry.password = password;
      const credential = buildPasswordCredential(password);
      const parts = profile.displayName.split(' ');
      const record = { uuid_source: crypto.randomUUID(), prenom: parts.slice(0, -1).join(' '),
        nom: parts.at(-1), email, etablissements_id: 2,
        mot_de_passe: credential.serialized, created_at: new Date().toISOString() };
      await request(`/api/v2/tables/${table}/records`, record);
      const confirmed = await request(`/api/v2/tables/${table}/records?${query}`);
      if (confirmed.list?.length !== 1 || confirmed.list[0].mot_de_passe !== credential.serialized) {
        throw new Error('Account creation not confirmed; do not retry automatically');
      }
      entry.status = 'created';
    } catch (error) { entry.status = 'needs-verification'; entry.error = error.message; }
  }
  return results;
}

const script = `const result = await (${remote.toString()})(${JSON.stringify(TECHNICIAN_PROFILES)}, ${apply}); console.log(JSON.stringify(result));`;
const result = spawnSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
  '-i', '/Users/aidhabitat/.ssh/aidhabitat_hetzner_recovery', 'root@157.180.20.97',
  'docker exec -i $(docker ps --filter label=com.docker.swarm.service.name=apps_aidhabitat-api-staging -q) node --input-type=module'],
{ input: script, encoding: 'utf8', timeout: 150000, maxBuffer: 1000000 });
if (result.status !== 0) throw new Error('Remote provisioning stopped; inspect server connectivity before retrying');
const accounts = JSON.parse(result.stdout.trim());
if (apply) {
  fs.writeFileSync(output, ["Acces individuels Aid'Habitat - confidentiel",
    'Role Technicien et modele PDF : activation avec la prochaine version applicative.', '',
    ...accounts.map(a => [a.displayName, `Identifiant : ${a.email}`, `Etat : ${a.status}`,
      a.password ? `Mot de passe : ${a.password}` : 'Mot de passe existant non modifie.',
      a.error || '', ''].join('\n'))].join('\n'), { mode: 0o600, flag: 'wx' });
}
console.log(JSON.stringify({ apply, output: apply ? output : undefined,
  accounts: accounts.map(({ password, ...account }) => account) }, null, 2));
if (accounts.some(a => a.status === 'needs-verification')) process.exitCode = 1;
