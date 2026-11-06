import fs from 'node:fs/promises';
import path from 'node:path';

// Container logs vanish at each deployment. This file keeps rejected sync
// writes so their causes can be counted. It stores metadata only: never the
// request body, remoteData, dossier, patient or user identifiers.
const SYNC_WRITE_PATH = new RegExp('^/api/(?:beneficiaires|dossiers|logements|contextes|'
  + 'diagnostic-sanitaires|mesures|observations|note-pages|documents|'
  + 'visit-recommendations|visit-photo-order)(?:/|$)');
const WRITE_METHODS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const CODE = /^[A-Z][A-Z0-9_]{1,95}$/;
const FIELD = /^[\p{L}_][\p{L}\p{N}_]{0,95}$/u;
const WRITE_ID = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const MAX_FIELDS = 50;
const DEFAULT_MAX_FILE_BYTES = 20 * 1024 * 1024;

const safeFields = (value) => (Array.isArray(value)
  ? value.filter((name) => typeof name === 'string' && FIELD.test(name)).slice(0, MAX_FIELDS)
  : []);

/** 401, 403 and 5xx are retried silently by clients and show no sync error. */
export const isReportedSyncRejection = (status) =>
  status >= 400 && status < 500 && status !== 401 && status !== 403;

export function syncRejectionEntry({ method, path: requestPath, status, body, at }) {
  return {
    at,
    method,
    resource: requestPath.split('/')[2],
    status,
    code: typeof body?.error === 'string' && CODE.test(body.error) ? body.error : null,
    conflictFields: safeFields(body?.conflictFields),
    retainedFields: safeFields(body?.retainedFields),
    writeId: typeof body?.writeId === 'string' && WRITE_ID.test(body.writeId) ? body.writeId : null,
  };
}

export function createSyncRejectionLog({ directory, maxFileBytes = DEFAULT_MAX_FILE_BYTES,
  now = () => new Date() }) {
  let queue = Promise.resolve();
  const append = async (entry) => {
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const filename = path.join(directory, `sync-rejections-${entry.at.slice(0, 7)}.jsonl`);
    const size = await fs.stat(filename).then((info) => info.size, (error) => {
      if (error.code === 'ENOENT') return 0;
      throw error;
    });
    if (size >= maxFileBytes) return;
    await fs.appendFile(filename, `${JSON.stringify(entry)}\n`, { mode: 0o600 });
  };
  const record = (entry) => {
    queue = queue.then(() => append(entry)).catch((error) => {
      console.warn('[sync-rejection-log] unavailable', error?.code || 'UNKNOWN');
    });
  };
  const middleware = (req, res, next) => {
    if (WRITE_METHODS.has(req.method) && SYNC_WRITE_PATH.test(req.path)) {
      const json = res.json.bind(res);
      res.json = (body) => {
        // Diagnostics must never change or delay the response.
        try {
          if (isReportedSyncRejection(res.statusCode)) {
            record(syncRejectionEntry({ method: req.method, path: req.path,
              status: res.statusCode, body, at: now().toISOString() }));
          }
        } catch { /* The response matters more than this diagnostic. */ }
        return json(body);
      };
    }
    next();
  };
  return { middleware, flush: () => queue };
}
