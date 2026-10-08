#!/usr/bin/env node
import fs from 'node:fs/promises';
import { decryptNoteBackup } from '../server/noteBackup.mjs';

// Offline recovery only: never contacts the API or alters notes/sync queues.
// Supply an escrow keyring file, not secret keys as command-line arguments.
try {
  const args = process.argv.slice(2);
  const get = flag => { const i = args.indexOf(flag); return i >= 0 ? args[i + 1] : null; };
  const archive = get('--archive'), keysFile = get('--keys-file'), owner = get('--owner'), output = get('--out');
  if (!archive || !keysFile || !owner || !output) throw new Error('arguments');
  if ((await fs.stat(archive)).size > 64 * 1024 * 1024 || (await fs.stat(keysFile)).size > 65536) throw new Error('size');
  const envelope = JSON.parse(await fs.readFile(archive, 'utf8'));
  const encodedKeys = JSON.parse(await fs.readFile(keysFile, 'utf8'));
  const keyring = Object.fromEntries(Object.entries(encodedKeys).map(([id, value]) => [id, Buffer.from(value, 'base64')]));
  const restored = decryptNoteBackup(envelope, { owner, backupId: envelope.backupId, keyring });
  const handle = await fs.open(output, 'wx', 0o600);
  try { await handle.writeFile(restored.snapshotJson, 'utf8'); await handle.sync(); } finally { await handle.close(); }
  console.log(JSON.stringify({ verified: true, sha256: restored.receipt.sha256, bytes: restored.receipt.bytes }));
} catch {
  console.error('NOTE_BACKUP_VERIFY_FAILED: check arguments, key escrow, owner and archive integrity. Output is never overwritten.');
  process.exitCode = 1;
}
