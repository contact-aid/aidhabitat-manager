import express from 'express';
import fs from 'node:fs/promises';
import path from 'node:path';
import { VisitStore, VisitProcessor, createVisitProvider, visitDigest, visitError, validVisitId } from './visitAssistant.mjs';

export function registerVisitAssistantRoutes(app, { requireAuth, ensureDossierRecord,
  canAccessDossierRecord, field, dataDir, env = process.env, provider = createVisitProvider({ env }) }) {
  const store = new VisitStore(path.join(dataDir, 'visit-assistant'));
  const processor = new VisitProcessor({ store, provider, loadStyle: async author => {
    // Profiles are server-controlled and versioned. Only a corpus whose author
    // was checked in the source documents may personalize a draft.
    if (!env.VISIT_STYLE_PROFILES_PATH) return null;
    const profiles = JSON.parse(await fs.readFile(env.VISIT_STYLE_PROFILES_PATH, 'utf8'));
    const normalize = value => String(value).normalize('NFD').replace(/[\u0300-\u036f]/g, '').trim().toLowerCase();
    const profile = Object.entries(profiles).find(([key, value]) =>
      [key, ...(value.aliases ?? [])].some(name => normalize(name) === normalize(author)))?.[1];
    return profile?.sourceReview?.authorVerified === true ? profile : null;
  } });
  const publicJob = job => ({ id: job.id, createdAt: job.createdAt, status: job.status,
    transcript: job.transcript, handwrittenText: job.handwrittenText ?? [], result: job.result,
    error: job.error ?? null, styleVersion: job.styleVersion ?? null });
  const authorize = async req => {
    if (env.VISIT_ASSISTANT_ENABLED !== 'true') throw visitError(503, 'Assistant de visite non activé sur ce serveur.');
    const dossier = await ensureDossierRecord(req.params.dossierId);
    if (!dossier || !canAccessDossierRecord(req.appUser, dossier)) throw visitError(403, 'Accès interdit à ce dossier.');
    return { dossierId: String(field(dossier, 'uuid_source') || req.params.dossierId), author: String(field(dossier, 'ergo_id') || '') };
  };
  const owned = async (req, dossierId) => {
    const job = await store.read(dossierId, req.params.id);
    if (!job || job.owner !== req.appUser.email.toLowerCase()) throw visitError(404, 'Enregistrement introuvable.');
    return job;
  };
  const route = handler => async (req, res, next) => {
    try { await handler(req, res); } catch (error) {
      // AI/transport errors must never reach the generic request logger.
      res.status(error.statusCode || 503).json({ success: false, error: error.statusCode ? error.message : 'Traitement indisponible. Les données sont conservées.' });
    }
  };
  const root = '/api/visit-assistant/:dossierId';
  const rawAudio = express.raw({ type: 'application/octet-stream', limit: '2mb' });
  const parseAudio = (req, res, next) => rawAudio(req, res, error => {
    if (error) res.status(413).json({ success: false, error: 'Extrait trop volumineux ou transfert interrompu.' });
    else next();
  });
  app.get(root, requireAuth, route(async (req, res) => {
    const { dossierId } = await authorize(req);
    res.json({ success: true, data: (await store.list(dossierId)).filter(j => j.owner === req.appUser.email.toLowerCase()).map(publicJob) });
  }));
  app.put(`${root}/:id`, requireAuth, route(async (req, res) => {
    const { dossierId, author } = await authorize(req);
    if (!validVisitId(req.params.id)) throw visitError(400, 'Identifiant invalide.');
    const context = req.body?.context;
    if (!context || typeof context !== 'object' || JSON.stringify(context).length > 10_000_000 ||
        !Array.isArray(context.handwritten ?? []) || (context.handwritten?.length ?? 0) > 30) throw visitError(400, 'Contexte de visite invalide.');
    const job = await store.locked(dossierId, req.params.id, async () => {
      const previous = await store.read(dossierId, req.params.id);
      if (previous) return owned(req, dossierId);
      const job = { id: req.params.id, dossierId, author, owner: req.appUser.email.toLowerCase(),
        context, status: 'uploading', chunks: [], transcript: [], result: null,
        createdAt: new Date().toISOString() };
      await store.write(job);
      return job;
    });
    res.json({ success: true, data: publicJob(job) });
  }));
  app.put(`${root}/:id/chunks/:index`, requireAuth, parseAudio, route(async (req, res) => {
    const { dossierId } = await authorize(req);
    const index = Number(req.params.index);
    const duration = Number(req.headers['x-audio-duration']);
    if (!Number.isInteger(index) || index < 0 || index >= 240 || !Buffer.isBuffer(req.body) || req.body.length < 24 ||
        !Number.isFinite(duration) || duration <= 0 || duration > 90 || !req.body.subarray(4, 12).includes(Buffer.from('ftyp'))) {
      throw visitError(400, 'Extrait audio invalide.');
    }
    const sha = visitDigest(req.body);
    if (sha !== req.headers['x-audio-sha256']) throw visitError(400, 'Intégrité de l’extrait audio incorrecte.');
    await store.locked(dossierId, req.params.id, async () => {
      const job = await owned(req, dossierId);
      if (job.chunks[index]) {
        if (job.chunks[index].sha !== sha) throw visitError(409, 'Cet extrait existe avec un autre contenu.');
        return;
      }
      if (job.status !== 'uploading' || index !== job.chunks.length) throw visitError(409, 'Ordre des extraits invalide.');
      const filename = path.join(store.dir(dossierId, job.id), `${index}.m4a`);
      await fs.writeFile(`${filename}.tmp`, req.body, { mode: 0o600 });
      await fs.rename(`${filename}.tmp`, filename);
      job.chunks.push({ sha, duration });
      await store.write(job);
    });
    res.json({ success: true });
  }));
  app.post(`${root}/:id/finish`, requireAuth, route(async (req, res) => {
    const { dossierId } = await authorize(req);
    const job = await store.locked(dossierId, req.params.id, async () => {
      const job = await owned(req, dossierId);
      if (!Number.isInteger(req.body?.chunkCount) || job.chunks.length !== req.body.chunkCount || !job.chunks.length) throw visitError(409, 'Enregistrement incomplet.');
      if (job.status === 'uploading') {
        job.chunkCount = job.chunks.length;
        job.status = 'transcribing';
        await store.write(job);
      }
      return job;
    });
    res.json({ success: true, data: publicJob(job) });
  }));
  app.post(`${root}/:id/process`, requireAuth, route(async (req, res) => {
    const { dossierId } = await authorize(req);
    await owned(req, dossierId);
    res.json({ success: true, data: publicJob(await processor.step(dossierId, req.params.id)) });
  }));
  const chatActive = new Set();
  app.post(`${root}/:id/chat`, requireAuth, route(async (req, res) => {
    const { dossierId } = await authorize(req);
    const job = await owned(req, dossierId);
    const question = req.body?.question;
    if (typeof question !== 'string' || !question.trim() || question.length > 2000) throw visitError(400, 'Question invalide.');
    if (!job.transcript.length) throw visitError(409, 'La transcription n’est pas encore disponible.');
    const key = req.appUser.email;
    if (chatActive.has(key)) throw visitError(429, 'Une réponse est déjà en cours.');
    chatActive.add(key);
    try { res.json({ success: true, data: await provider.ask(job, question) }); }
    finally { chatActive.delete(key); }
  }));
  return { store, processor };
}
