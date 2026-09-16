import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export class RetentionError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

const validDay = (value) => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
  && Number.isFinite(Date.parse(value)) && new Date(value).toISOString().slice(0, 10) === value;

const businessDay = (date) => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Europe/Paris', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(date);

export function addCalendarMonths(day, months) {
  const date = new Date(`${day}T00:00:00Z`);
  const first = new Date(date);
  first.setUTCDate(1);
  first.setUTCMonth(first.getUTCMonth() + months);
  const end = new Date(first);
  end.setUTCMonth(end.getUTCMonth() + 1, 0);
  const lastDay = end.getUTCDate();
  first.setUTCDate(Math.min(date.getUTCDate(), lastDay));
  return first.toISOString().slice(0, 10);
}

export function validateRetentionRecord(input, now = new Date()) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new RetentionError('Objet requis');
  const keys = ['kind', 'id', 'expectedRevision', 'lastContactOn', 'closedOn', 'resolvedOn', 'hold', 'holdReference', 'exceptionsReviewed'];
  if (Object.keys(input).some(key => !keys.includes(key))) throw new RetentionError('Champ inconnu');
  if (!['dossier', 'feedback'].includes(input.kind)) throw new RetentionError('Categorie invalide');
  if (typeof input.id !== 'string' || !/^[A-Za-z0-9_-]{1,160}$/.test(input.id)) throw new RetentionError('Identifiant opaque requis');
  if (!Number.isSafeInteger(input.expectedRevision) || input.expectedRevision < 0) throw new RetentionError('Revision requise');
  if (typeof input.hold !== 'boolean' || typeof input.exceptionsReviewed !== 'boolean') throw new RetentionError('Indiquer blocage et verification des exceptions');
  const record = { kind: input.kind, id: input.id, hold: input.hold, exceptionsReviewed: input.exceptionsReviewed };
  const today = businessDay(now);
  for (const field of ['lastContactOn', 'closedOn', 'resolvedOn']) {
    const value = input[field] ?? null;
    if (value !== null && (!validDay(value) || value > today)) throw new RetentionError(`Date invalide : ${field}`);
    record[field] = value;
  }
  if (input.kind === 'dossier' && record.resolvedOn !== null) throw new RetentionError('Resolution reservee aux signalements');
  if (input.kind === 'feedback' && (record.lastContactOn !== null || record.closedOn !== null)) throw new RetentionError('Contact et cloture reserves aux dossiers');
  if (record.closedOn && record.lastContactOn && record.closedOn < record.lastContactOn) throw new RetentionError('Cloture anterieure au dernier contact');
  record.holdReference = input.holdReference ?? null;
  if (record.holdReference !== null && (typeof record.holdReference !== 'string' || !/^[A-Za-z0-9_.:-]{1,160}$/.test(record.holdReference))) throw new RetentionError('Reference interne uniquement, sans texte personnel');
  if (record.hold && !record.holdReference) throw new RetentionError('Reference du blocage requise');
  if (!record.hold && record.holdReference) throw new RetentionError('Reference sans blocage');
  return record;
}

export function buildRetentionReport(events, today = businessDay(new Date())) {
  if (!validDay(today)) throw new RetentionError('Date de rapport invalide');
  const latest = new Map();
  for (const event of events) latest.set(`${event.record.kind}:${event.record.id}`, event);
  const items = [...latest.values()].map(({ record, revision }) => {
    const anchor = record.kind === 'dossier' ? record.lastContactOn : record.resolvedOn;
    const dueOn = anchor ? addCalendarMonths(anchor, record.kind === 'dossier' ? 24 : 6) : null;
    const blockers = [];
    if (!anchor) blockers.push('missing_business_date');
    if (record.kind === 'dossier' && !record.closedOn) blockers.push('dossier_not_closed');
    if (record.hold) blockers.push('retention_hold');
    if (!record.exceptionsReviewed) blockers.push('exceptions_not_reviewed');
    const status = blockers.length ? 'blocked' : dueOn <= today ? 'review_due' : 'not_due';
    return { ...record, revision, dueOn, status, blockers, deletionAllowed: false };
  });
  return {
    asOf: today, mode: 'review-only', coverage: 'registered-records-only',
    deletionEnabled: false, copiesVerified: false,
    requiredChecks: ['source_record_exists', 'attachments', 'offline_copies', 'mail_copies', 'backup_rotation', 'restoration_test'],
    items,
  };
}

export function createRetentionStore(file, now = () => new Date()) {
  const filename = file instanceof URL ? fileURLToPath(file) : file;
  const read = async () => {
    let text;
    try { text = await fs.readFile(filename, 'utf8'); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
    try {
      if (text && !text.endsWith('\n')) throw new Error('Event incomplet');
      const events = text.split('\n').filter(Boolean).map(line => JSON.parse(line));
      const revisions = new Map();
      for (const event of events) {
        if (event.version !== 1 || typeof event.actor !== 'string' || !event.actor || !Number.isFinite(Date.parse(event.at))) throw new Error('Event invalide');
        validateRetentionRecord({ ...event.record, expectedRevision: 0 }, now());
        const key = `${event.record.kind}:${event.record.id}`;
        if (event.revision !== (revisions.get(key) ?? 0) + 1) throw new Error('Revision invalide');
        revisions.set(key, event.revision);
      }
      return events;
    } catch { throw new RetentionError('Registre illisible : aucune modification autorisee', 503); }
  };
  const update = async (input, actor) => {
    const record = validateRetentionRecord(input, now());
    if (typeof actor !== 'string' || !actor.trim() || actor.length > 200) throw new RetentionError('Auteur requis');
    await fs.mkdir(path.dirname(filename), { recursive: true });
    let lock;
    try { lock = await fs.open(`${filename}.lock`, 'wx', 0o600); }
    catch (error) {
      if (error.code === 'EEXIST') throw new RetentionError('Registre occupe ; reessayer ou verifier le verrou', 409);
      throw error;
    }
    try {
      const events = await read();
      const previous = events.findLast(event => event.record.kind === record.kind && event.record.id === record.id);
      const revision = previous?.revision ?? 0;
      if (input.expectedRevision !== revision) throw new RetentionError('Revision obsolete ; relire le registre', 409);
      const event = { version: 1, at: now().toISOString(), actor, revision: revision + 1, record };
      // Append and fsync preserve an audit trail. Corrupt or partial logs fail closed.
      const handle = await fs.open(filename, 'a', 0o600);
      try { await handle.writeFile(`${JSON.stringify(event)}\n`); await handle.sync(); }
      finally { await handle.close(); }
      return event;
    } finally { await lock.close(); await fs.unlink(`${filename}.lock`); }
  };
  return { read, update, report: async () => buildRetentionReport(await read(), businessDay(now())) };
}
