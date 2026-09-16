#!/usr/bin/env node
import path from 'node:path';
import { createRetentionStore } from '../server/dataRetention.mjs';

const args = process.argv.slice(2);
if (args.length !== 1 || args[0].startsWith('-')) {
  console.error('Usage: node tools/data-retention-report.mjs <retention-events.jsonl>');
  process.exitCode = 1;
} else {
  try {
    // Explicit path only: no dotenv, backend calls or writes.
    const { access } = await import('node:fs/promises');
    const file = path.resolve(args[0]);
    await access(file);
    console.log(JSON.stringify(await createRetentionStore(file).report(), null, 2));
  } catch {
    console.error('Rapport impossible : verifier le chemin, les droits et l\'integrite du registre. Aucun changement effectue.');
    process.exitCode = 1;
  }
}
