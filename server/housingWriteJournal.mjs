import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { SyncMutationError } from './guardedMutation.mjs';
import { createKeyedSerialExecutor } from './keyedSerialExecutor.mjs';

// A revision alone remembers only the latest writer. Keep the original CAS
// for every new-protocol housing write so an old retry cannot become a new
// write after another device has edited the record, including an ABA change.
export function createJournaledHousingWriter({ directory, writer, readRecord }) {
  const serialize = createKeyedSerialExecutor();
  const persist = async (filename, value, exclusive = false) => {
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const temporary = `${filename}.${randomUUID()}.tmp`;
    const handle = await fs.open(temporary, 'wx', 0o600);
    try { await handle.writeFile(JSON.stringify(value)); await handle.sync(); }
    finally { await handle.close(); }
    try {
      // Linking a fully synced temporary file publishes the initial journal
      // atomically without replacing a receipt created by another process.
      if (exclusive) await fs.link(temporary, filename);
      else await fs.rename(temporary, filename);
      const dir = await fs.open(directory, 'r');
      try { await dir.sync(); } finally { await dir.close(); }
    } finally { await fs.rm(temporary, { force: true }); }
  };
  return async (input) => {
    const args = structuredClone(input);
    const key = createHash('sha256').update(JSON.stringify([
      args.tableId, args.recordId, args.writeId,
    ])).digest('hex');
    return serialize(key, async () => {
      const filename = path.join(directory, `${key}.json`);
      let receipt;
      let initial = false;
      try { receipt = JSON.parse(await fs.readFile(filename, 'utf8')); }
      catch (error) {
        if (error.code !== 'ENOENT') throw error;
        receipt = { version: 1, status: 'pending', args,
          before: await readRecord(args.tableId, args.recordId),
          createdAt: new Date().toISOString() };
        try { await persist(filename, receipt, true); initial = true; }
        catch (error) {
          if (error.code !== 'EEXIST') throw error;
          receipt = JSON.parse(await fs.readFile(filename, 'utf8'));
        }
      }
      if (receipt.version !== 1 || !receipt.args ||
          receipt.args.tableId !== args.tableId || receipt.args.recordId !== args.recordId ||
          receipt.args.writeId !== args.writeId ||
          !isDeepStrictEqual(receipt.args.fields, args.fields)) {
        throw new SyncMutationError(409, 'SYNC_WRITE_ID_MISMATCH');
      }
      const superseded = async () => {
        throw new SyncMutationError(409, 'SYNC_HOUSING_WRITE_SUPERSEDED',
          await readRecord(args.tableId, args.recordId));
      };
      if (receipt.status === 'applied') return superseded();
      if (receipt.status === 'rejected') {
        throw new SyncMutationError(409, 'SYNC_FIELD_CONFLICT',
          await readRecord(args.tableId, args.recordId),
          { conflicts: Object.keys(args.fields), retainedFields: [] });
      }
      if (receipt.status !== 'pending') throw new Error('Invalid housing write journal');
      // Never refresh the expected revision of an uncertain transmission.
      const result = await writer(receipt.args);
      if (result.status === 'applied') {
        await persist(filename, { ...receipt, status: 'applied', result,
          confirmedAt: new Date().toISOString() });
        return result;
      }
      if (result.reason === 'revision_changed') {
        if (!initial) return superseded();
        await persist(filename, { ...receipt, status: 'rejected' });
        throw new SyncMutationError(409, 'SYNC_FIELD_CONFLICT', result.observed,
          { conflicts: Object.keys(args.fields), retainedFields: [] });
      }
      return result;
    });
  };
}
