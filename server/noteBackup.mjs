import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import path from 'node:path';
import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export const NOTE_BACKUP_MAX_BYTES = 20 * 1024 * 1024;
const MAX_FILE_BYTES = 64 * 1024 * 1024;
const hash = value => createHash('sha256').update(value).digest('hex');
const idPattern = /^[a-f0-9]{64}$/;
export class NoteBackupError extends Error {
  constructor(code = 'NOTE_BACKUP_UNAVAILABLE', status = 503) {
    super(code); this.code = code; this.status = this.statusCode = status;
  }
}
const unavailable = () => { throw new NoteBackupError(); };
const validString = value => typeof value === 'string' && value.length > 0 && value.length <= 512;
export function validateNoteSnapshot(patientId, snapshotJson) {
  if (!validString(patientId) || typeof snapshotJson !== 'string') throw new NoteBackupError('NOTE_BACKUP_INVALID', 400);
  const bytes = Buffer.byteLength(snapshotJson);
  if (bytes > NOTE_BACKUP_MAX_BYTES) throw new NoteBackupError('NOTE_BACKUP_TOO_LARGE', 413);
  let data;
  try { data = JSON.parse(snapshotJson); } catch { throw new NoteBackupError('NOTE_BACKUP_INVALID', 400); }
  if (!data || data.schemaVersion !== 1 || data.entityType !== 'note_page'
    || !validString(data.operationId) || !validString(data.entityLocalId)
    || !data.payload || data.payload.patientLocalId !== patientId
    || (data.payload.patientId != null && data.payload.patientId !== patientId)
    || typeof data.payload.drawingJson !== 'string'
    || !validString(data.payload.tabKey)
    || !Number.isInteger(data.payload.pageNumber) || data.payload.pageNumber < 0
    || (data.localNote != null && (typeof data.localNote !== 'object'
      || typeof data.localNote.drawingJson !== 'string'
      || (data.localNote.patientId != null && data.localNote.patientId !== patientId)
      || (data.localNote.patientLocalId != null && data.localNote.patientLocalId !== patientId)
      || (data.localNote.patient_local_id != null && data.localNote.patient_local_id !== patientId)
      || (data.localNote.local_id != null && data.localNote.local_id !== data.entityLocalId)))) {
    throw new NoteBackupError('NOTE_BACKUP_INVALID', 400);
  }
  return { bytes, sha256: hash(Buffer.from(snapshotJson, 'utf8')) };
}

// Stable server account identity; never supplied by the request body.
export function noteBackupOwner(user) {
  if (!validString(user?.ergoRecordId)) throw new NoteBackupError('NOTE_BACKUP_OWNER_REQUIRED', 403);
  return `ergo:${user.ergoRecordId}`;
}
export function noteBackupConfig(env = process.env) {
  if (env.AIDHABITAT_NOTE_BACKUP_ENABLED !== '1') return null;
  try {
    const directory = env.AIDHABITAT_NOTE_BACKUP_DIR;
    const activeKeyId = env.AIDHABITAT_NOTE_BACKUP_KEY_ID;
    const keys = JSON.parse(env.AIDHABITAT_NOTE_BACKUP_KEYS_JSON || '{}');
    if (!directory || !path.isAbsolute(directory) || env.AIDHABITAT_NOTE_BACKUP_DURABLE !== '1'
      || !keys || Array.isArray(keys) || typeof keys !== 'object'
      || !/^[A-Za-z0-9_-]{1,64}$/.test(activeKeyId || '') || !Object.hasOwn(keys, activeKeyId)) unavailable();
    const keyring = Object.create(null);
    for (const [id, encoded] of Object.entries(keys)) {
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(id) || typeof encoded !== 'string') unavailable();
      const key = Buffer.from(encoded, 'base64');
      if (key.length !== 32 || key.toString('base64') !== encoded) unavailable();
      keyring[id] = key;
    }
    return { directory, activeKeyId, keyring };
  } catch { unavailable(); }
}
const aad = envelope => Buffer.from(JSON.stringify([
  'appergo-note-backup-v1', envelope.ownerHash, envelope.backupId, envelope.keyId,
]));
const backupIdFor = (ownerHash, patientId, source, sha256) => hash(JSON.stringify([ownerHash, patientId, source, sha256]));
export function decryptNoteBackup(envelope, { owner, backupId, keyring }) {
  try {
    if (envelope.version !== 1 || envelope.algorithm !== 'AES-256-GCM'
      || envelope.ownerHash !== hash(owner) || envelope.backupId !== backupId
      || !idPattern.test(backupId) || !keyring[envelope.keyId]) unavailable();
    const nonce = Buffer.from(envelope.nonce, 'base64');
    const tag = Buffer.from(envelope.tag, 'base64');
    if (nonce.length !== 12 || tag.length !== 16) unavailable();
    const decipher = createDecipheriv('aes-256-gcm', keyring[envelope.keyId], nonce);
    decipher.setAAD(aad(envelope)); decipher.setAuthTag(tag);
    const decoded = Buffer.concat([decipher.update(Buffer.from(envelope.ciphertext, 'base64')), decipher.final()]);
    if (decoded.length > MAX_FILE_BYTES) unavailable();
    const data = JSON.parse(decoded.toString('utf8'));
    const verified = validateNoteSnapshot(data.patientId, data.snapshotJson);
    if (!['local-operation', 'sync-request'].includes(data.source)
      || backupIdFor(envelope.ownerHash, data.patientId, data.source, verified.sha256) !== backupId
      || typeof data.createdAt !== 'string' || !Number.isFinite(Date.parse(data.createdAt))) unavailable();
    return { patientId: data.patientId, snapshotJson: data.snapshotJson,
      receipt: { backupId, ...verified, createdAt: data.createdAt, source: data.source, storedVerified: true } };
  } catch { unavailable(); }
}
export function createNoteBackupStore(config) {
  const ensure = async owner => {
    if (!config || !validString(owner)) unavailable();
    const root = path.resolve(config.directory);
    if (await fs.realpath(root) !== root) unavailable();
    const info = await fs.lstat(root);
    if (!info.isDirectory() || (info.mode & 0o077) !== 0) unavailable();
    const directory = path.join(root, hash(owner));
    await fs.mkdir(directory, { mode: 0o700 });
    return directory;
  };
  const directoryFor = async (owner, create = false) => {
    if (!config || !validString(owner)) unavailable();
    try {
      if (create) {
        try { await ensure(owner); } catch (e) { if (e.code !== 'EEXIST') throw e; }
      }
      const root = path.resolve(config.directory);
      if (await fs.realpath(root) !== root) unavailable();
      const rootInfo = await fs.lstat(root);
      if (!rootInfo.isDirectory() || (rootInfo.mode & 0o077) !== 0) unavailable();
      const directory = path.join(root, hash(owner));
      const info = await fs.lstat(directory);
      if (!info.isDirectory() || info.isSymbolicLink() || (info.mode & 0o077) !== 0) unavailable();
      return directory;
    } catch (e) {
      if (!create && e.code === 'ENOENT') throw new NoteBackupError('NOTE_BACKUP_NOT_FOUND', 404);
      throw new NoteBackupError();
    }
  };
  async function read(owner, backupId) {
    if (!idPattern.test(backupId || '')) throw new NoteBackupError('NOTE_BACKUP_NOT_FOUND', 404);
    const directory = await directoryFor(owner);
    let file;
    try {
      file = await fs.open(path.join(directory, `${backupId}.json`), constants.O_RDONLY | constants.O_NOFOLLOW);
      const info = await file.stat();
      if (!info.isFile() || info.size > MAX_FILE_BYTES) unavailable();
      return decryptNoteBackup(JSON.parse(await file.readFile('utf8')), { owner, backupId, keyring: config.keyring });
    } catch (e) {
      if (e.code === 'ENOENT') throw new NoteBackupError('NOTE_BACKUP_NOT_FOUND', 404);
      throw new NoteBackupError();
    } finally { await file?.close(); }
  }
  async function syncDirectory(directory) {
    const handle = await fs.open(directory, constants.O_RDONLY);
    try { await handle.sync(); } finally { await handle.close(); }
  }
  async function save({ owner, patientId, snapshotJson, source = 'local-operation' }) {
    if (!config) unavailable();
    const verified = validateNoteSnapshot(patientId, snapshotJson);
    if (!['local-operation', 'sync-request'].includes(source)) throw new NoteBackupError('NOTE_BACKUP_INVALID', 400);
    const directory = await directoryFor(owner, true);
    const ownerHash = hash(owner), backupId = backupIdFor(ownerHash, patientId, source, verified.sha256);
    try {
      const existing = await read(owner, backupId);
      await syncDirectory(directory); await syncDirectory(path.resolve(config.directory));
      return { ...existing, created: false };
    } catch (e) { if (e.code !== 'NOTE_BACKUP_NOT_FOUND') throw e; }
    const envelope = { version: 1, algorithm: 'AES-256-GCM', ownerHash, backupId, keyId: config.activeKeyId };
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', config.keyring[config.activeKeyId], nonce);
    cipher.setAAD(aad(envelope));
    const plaintext = Buffer.from(JSON.stringify({ patientId, snapshotJson, source, createdAt: new Date().toISOString() }));
    const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
    Object.assign(envelope, { nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext: ciphertext.toString('base64') });
    const temp = path.join(directory, `.${backupId}.${randomBytes(12).toString('hex')}.tmp`);
    let created = true;
    try {
      const handle = await fs.open(temp, 'wx', 0o600);
      try { await handle.writeFile(JSON.stringify(envelope)); await handle.sync(); } finally { await handle.close(); }
      try { await fs.link(temp, path.join(directory, `${backupId}.json`)); }
      catch (e) { if (e.code !== 'EEXIST') throw e; created = false; }
      await syncDirectory(directory); await syncDirectory(path.resolve(config.directory));
      // Receipt only follows an independent filesystem read and complete decrypt.
      return { ...await read(owner, backupId), created };
    } catch { unavailable(); }
    finally { await fs.unlink(temp).catch(() => {}); }
  }
  return { save, read };
}
