// Temporary LAN-only backend for the separate fictitious iPad preview.
// No NocoDB, production login, patient record or production document route.
import express from 'express';
import crypto from 'node:crypto';
import path from 'node:path';
import { registerVisitAssistantRoutes } from '../server/visitAssistantRoutes.mjs';

const host = process.env.VISIT_PREVIEW_HOST;
const port = Number(process.env.VISIT_PREVIEW_PORT || 3308);
const token = process.env.VISIT_PREVIEW_ACCESS_TOKEN;
if (!host || !/^(127\.|192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.)/.test(host) ||
    !token || token.length < 32 || !Number.isInteger(port)) {
  throw new Error('Private LAN host and preview-only access token required.');
}
const expected = Buffer.from(token);
const expiresAt = Date.now() + 12 * 60 * 60 * 1000;
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '12mb' }));
app.use((_req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
app.get('/api/preview-health', (_req, res) => res.json({ success: true, fictionalOnly: true }));
registerVisitAssistantRoutes(app, {
  env: { ...process.env, VISIT_ASSISTANT_ENABLED: 'true' },
  dataDir: path.join(process.env.AIDHABITAT_DATA_DIR_PATH, 'fictional-preview'),
  requireAuth: (req, res, next) => {
    const supplied = Buffer.from(String(req.headers['x-app-session'] || ''));
    if (Date.now() > expiresAt || supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) {
      return res.status(401).json({ error: 'Accès de test absent ou expiré.' });
    }
    req.appUser = { email: 'visit-test@example.invalid' };
    next();
  },
  ensureDossierRecord: async id => id === 'visit-test-dossier'
    ? { uuid_source: id, ergo_id: 'Coralie' } : null,
  canAccessDossierRecord: (_, dossier) => dossier?.uuid_source === 'visit-test-dossier',
  field: (record, key) => record[key],
});
app.use((_req, res) => res.status(404).json({ error: 'Route absente de la recette fictive.' }));
app.use((_error, _req, res, _next) => res.status(400).json({ error: 'Requête de test invalide.' }));
const server = app.listen(port, host, () => console.log('API de recette fictive disponible sur le réseau local. Aucun accès NocoDB.'));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close());
