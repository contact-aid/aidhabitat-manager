import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { createKeyedSerialExecutor } from './keyedSerialExecutor.mjs';
import { reportDocumentAliases } from './reports/inlineReportDocuments.mjs';

const visitTag = tags => (Array.isArray(tags) ? tags : []).find(t => String(t).startsWith('Visite - '));
export function createVisitPhotoOrderStore(directory) {
  const serialize = createKeyedSerialExecutor();
  const filename = patient => path.join(directory, `${crypto.createHash('sha256').update(patient).digest('hex')}.json`);
  const read = async patient => {
    try { return JSON.parse(await fs.readFile(filename(patient), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return { categories: {} }; throw error; }
  };
  const write = async (patient, state) => {
    await fs.mkdir(directory, { recursive: true });
    const temporary = `${filename(patient)}.${crypto.randomUUID()}.tmp`;
    await fs.writeFile(temporary, JSON.stringify(state), { mode: 0o600 });
    await fs.rename(temporary, filename(patient));
  };
  return {
    async save(patient, { categoryTag, orderedDocumentIds, mutationId, modifiedAt, initializeOnly = false }) {
      if (!String(categoryTag).startsWith('Visite - ') || String(categoryTag).length > 150 ||
          !Array.isArray(orderedDocumentIds) || orderedDocumentIds.length > 500 ||
          orderedDocumentIds.some(id => typeof id !== 'string' || !id || id.length > 1000) ||
          !mutationId || String(mutationId).length > 100 || !Number.isFinite(Date.parse(modifiedAt))) {
        throw Object.assign(new Error('Ordre des photos invalide'), { statusCode: 400 });
      }
      return serialize(patient, async () => {
        const state = await read(patient);
        const previous = state.categories[categoryTag];
        if (previous && (initializeOnly || previous.mutationId === mutationId ||
            Date.parse(previous.modifiedAt) > Date.parse(modifiedAt))) return previous;
        const snapshot = { mutationId, modifiedAt: initializeOnly ? '1970-01-01T00:00:00.000Z' : modifiedAt, orderedDocumentIds: [...new Set(orderedDocumentIds)] };
        state.categories[categoryTag] = snapshot;
        await write(patient, state);
        return snapshot;
      });
    },
    async apply(patient, documents) {
      return serialize(patient, async () => {
      const state = await read(patient);
      const groups = new Map();
      for (const doc of documents) {
        const tag = visitTag(doc.tags);
        if (tag && state.categories[tag]) {
          if (!groups.has(tag)) groups.set(tag, []);
          groups.get(tag).push(doc);
        }
      }
      const orders = new Map();
      let changed = false;
      for (const [tag, docs] of groups) {
        const snapshot = state.categories[tag];
        const positions = new Map(snapshot.orderedDocumentIds.map((id,i) => [id,i]));
        const rank = doc => reportDocumentAliases(doc, patient).map(id => positions.get(id)).find(v => v !== undefined);
        const unmatched = docs.filter(doc => rank(doc) === undefined).sort((a,b) =>
          String(b.createdAt || '').localeCompare(String(a.createdAt || '')) || String(a.id).localeCompare(String(b.id)));
        for (const doc of unmatched) {
          snapshot.orderedDocumentIds.push(String(doc.id));
          changed = true;
        }
        const finalPositions = new Map(snapshot.orderedDocumentIds.map((id,i) => [id,i]));
        for (const doc of docs) orders.set(doc, reportDocumentAliases(doc, patient).map(id => finalPositions.get(id)).find(v => v !== undefined));
      }
      if (changed) await write(patient, state);
      return documents.map(doc => orders.has(doc)
        ? { ...doc, categoryOrder: orders.get(doc), photoOrderShared: true }
        : doc);
      });
    },
  };
}
