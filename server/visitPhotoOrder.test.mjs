import assert from 'node:assert/strict';
import test from 'node:test';
import { photosForVisitTag, generateVisitReport } from './reports/generateVisitReport.mjs';

const tag = 'Visite - Accessibilité';
const photos = ['a', 'b', 'c'].map((id, i) => ({
  id, tags: [tag], createdAt: `2026-10-01T10:00:0${i}Z`,
  updatedAt: `2026-10-02T10:00:0${2-i}Z`,
}));
test('photo fallback order uses capture time and stable identity, never modification time', () => {
  const first = photosForVisitTag(photos, tag).map(p => p.id);
  const later = photos.map(p => ({ ...p, updatedAt: '2099-01-01' })).reverse();
  assert.deepEqual(photosForVisitTag(later, tag).map(p => p.id), first);
  const ties = photos.map(p => ({ ...p, createdAt: photos[0].createdAt }));
  assert.deepEqual(photosForVisitTag(ties.reverse(), tag).map(p => p.id), ['a', 'b', 'c']);
});
test('explicit photo order wins over every timestamp and category is preserved', () => {
  const ranked = photos.map((p, i) => ({ ...p, categoryOrder: [2, 0, 1][i] }));
  assert.deepEqual(photosForVisitTag([...ranked, { id: 'other', tags: ['Visite - Sanitaires'], categoryOrder: 0 }], tag).map(p => p.id), ['b', 'c', 'a']);
});
test('real report requests accessibility images in their saved order', async () => {
  const seen = [];
  await generateVisitReport({
    dossier: { patient: { firstName: 'Alice', lastName: 'EXEMPLE' }, housing: {} },
    documents: photos.map((p, i) => ({ ...p, categoryOrder: [2, 0, 1][i] })),
    fetchImageBytes: async doc => { if (!seen.includes(doc.id)) seen.push(doc.id); return null; },
  });
  assert.deepEqual(seen, ['b', 'c', 'a']);
});
