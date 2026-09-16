import express from 'express';
import { dataFileUrl } from '../helpers.mjs';
import { requireAdmin } from '../middleware/auth.mjs';
import { createRetentionStore, RetentionError } from '../dataRetention.mjs';

export function createDataRetentionRouter({ authorize = requireAdmin, store = createRetentionStore(dataFileUrl('retention-events.jsonl')) } = {}) {
  const router = express.Router();
  router.use('/api/admin/data-retention', authorize, (_req, res, next) => {
    res.set('Cache-Control', 'no-store');
    next();
  });
  router.get('/api/admin/data-retention', async (_req, res, next) => {
    try { res.json({ success: true, ...await store.report() }); }
    catch (error) { next(error); }
  });
  router.post('/api/admin/data-retention', async (req, res, next) => {
    try {
      const actor = req.appUser?.id || req.appUser?.email;
      const event = await store.update(req.body, actor);
      res.json({ success: true, revision: event.revision, record: event.record, deletionEnabled: false });
    } catch (error) { next(error); }
  });
  router.use((error, _req, res, next) => {
    if (error instanceof RetentionError) res.status(error.status).json({ success: false, error: error.message });
    else next(error);
  });
  return router;
}

export default createDataRetentionRouter();
