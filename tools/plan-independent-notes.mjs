#!/usr/bin/env node
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import { planIndependentNotes } from '../server/independentNotes.mjs';

// Offline review only. No apply mode, database client, credentials or network.
const [filename, ...extra] = process.argv.slice(2);
if (!filename || extra.length) throw new Error('Usage: node tools/plan-independent-notes.mjs snapshot.json');
const raw = await fs.readFile(filename, 'utf8');
const snapshot = JSON.parse(raw);
if (snapshot.version !== 1 || !['synthetic', 'staging'].includes(snapshot.environment)
    || !Array.isArray(snapshot.dossiers)) {
  throw new Error('Un snapshot version 1 synthetic ou staging est requis');
}
const results = snapshot.dossiers.map(dossier => {
  if (!dossier.patientId || !dossier.dossierId || !Array.isArray(dossier.pages)) {
    throw new Error('Identités et pages requises pour chaque dossier');
  }
  try {
    return { dossierId: dossier.dossierId, writes: planIndependentNotes(dossier) };
  } catch (error) {
    return { dossierId: dossier.dossierId, blocked: error.message, writes: [] };
  }
});
process.stdout.write(`${JSON.stringify({ mode: 'review-only', environment: snapshot.environment,
  snapshotSha256: crypto.createHash('sha256').update(raw).digest('hex'), results }, null, 2)}\n`);
