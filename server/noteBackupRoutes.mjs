import { createNoteBackupStore, noteBackupConfig, noteBackupOwner, validateNoteSnapshot, NoteBackupError } from './noteBackup.mjs';

export function registerNoteBackupRoutes(app, { requireAuth, resolveBeneficiaryAccess, config = () => noteBackupConfig() }) {
  const handle = action => async (req, res) => {
    res.setHeader('Cache-Control', 'private, no-store');
    try { await action(req, res); }
    catch (error) {
      // Never log snapshots, cipher keys, access tokens or raw exception data.
      const known = error instanceof NoteBackupError;
      const accessDenied = [401, 403, 404].includes(Number(error?.statusCode || error?.status));
      res.status(known || accessDenied ? Number(error.statusCode || error.status) : 503)
        .json({ success: false, error: known ? error.code : accessDenied ? 'NOTE_BACKUP_ACCESS_DENIED' : 'NOTE_BACKUP_UNAVAILABLE' });
    }
  };
  app.post('/api/note-backups', requireAuth, handle(async (req, res) => {
    const settings = config();
    if (!settings) throw new NoteBackupError();
    const { patientId, snapshotJson } = req.body || {};
    validateNoteSnapshot(patientId, snapshotJson);
    await resolveBeneficiaryAccess(req.appUser, patientId);
    const saved = await createNoteBackupStore(settings).save({ owner: noteBackupOwner(req.appUser), patientId, snapshotJson });
    res.status(saved.created ? 201 : 200).json({ success: true, data: { receipt: saved.receipt } });
  }));
  const read = content => handle(async (req, res) => {
    const settings = config();
    if (!settings) throw new NoteBackupError();
    const saved = await createNoteBackupStore(settings).read(noteBackupOwner(req.appUser), req.params.backupId);
    await resolveBeneficiaryAccess(req.appUser, saved.patientId);
    res.json({ success: true, data: content ? saved : { receipt: saved.receipt } });
  });
  app.get('/api/note-backups/:backupId/content', requireAuth, read(true));
  app.get('/api/note-backups/:backupId', requireAuth, read(false));
}

// Passive capture has its own switch and an exact allowlist. Explicit owner
// exports remain independent. Never infer broad collection from backup enablement.
export function shouldCaptureSubmittedNote(req, env = process.env) {
  if (env.AIDHABITAT_NOTE_BACKUP_CAPTURE_ENABLED !== '1') return false;
  let targets;
  try { targets = JSON.parse(env.AIDHABITAT_NOTE_BACKUP_CAPTURE_TARGETS_JSON || '[]'); }
  catch { throw new NoteBackupError(); }
  if (!Array.isArray(targets) || targets.length > 32 || targets.some(target =>
    !target || typeof target !== 'object'
    || ['owner', 'patientId', 'tabKey'].some(key => typeof target[key] !== 'string' || !target[key] || target[key].length > 512)
    || !Number.isInteger(target.pageNumber) || target.pageNumber < 0
    || Object.keys(target).some(key => !['owner', 'patientId', 'tabKey', 'pageNumber'].includes(key)))) {
    throw new NoteBackupError();
  }
  if (!targets.length) return false;
  const owner = noteBackupOwner(req.appUser), body = req.body || {};
  return targets.some(target => target.owner === owner && target.patientId === body.patientId
    && target.tabKey === body.tabKey && target.pageNumber === body.pageNumber);
}

// Caller has already authenticated and authorized the beneficiary. This is
// only a copy of the submitted request, not an export of the local operation.
export async function captureSubmittedNoteBackup(req, res) {
  try {
    if (!shouldCaptureSubmittedNote(req)) return;
    const config = noteBackupConfig();
    if (!config) return;
    const body = req.body || {};
    const snapshotJson = JSON.stringify({ schemaVersion: 1,
      operationId: `submitted:${body.writeId || ''}`, entityType: 'note_page',
      entityLocalId: body.notePageId || `submitted:${body.writeId || ''}`,
      payload: { ...body, patientLocalId: body.patientId }, localNote: null,
      status: 'submitted', createdAt: null, updatedAt: null });
    const saved = await createNoteBackupStore(config).save({ owner: noteBackupOwner(req.appUser),
      patientId: body.patientId, snapshotJson, source: 'sync-request' });
    res.locals.noteBackupReceipt = saved.receipt;
    res.locals.noteBackupStatus = 'verified';
  } catch {
    res.locals.noteBackupStatus = 'unavailable';
  }
}
