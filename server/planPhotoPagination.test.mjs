import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument, PDFPage } from 'pdf-lib';
import sharp from 'sharp';
import fs from 'node:fs/promises';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

test('all plan photos are contained, captioned, and paginated two per framed page', async () => {
  const documents = [
    ...Array.from({ length: 5 }, (_, i) => ({ id: `before-${i}`, tags: ['Visite - Plan avant', '__pdf_show_label'] })),
    ...Array.from({ length: 5 }, (_, i) => ({ id: `after-${i}`, tags: ['Visite - Plan après', '__pdf_show_label'] })),
    ...Array.from({ length: 3 }, (_, i) => ({ id: `project2-${i}`, tags: ['Visite - Plan après (#2)', '__pdf_show_label'] })),
  ].map((doc, categoryOrder) => ({ ...doc, categoryOrder, title: `Plan ${doc.id} : description à conserver sous la photo` }));
  const dimensions = [[640, 420], [420, 640], [900, 900]];
  const buffers = await Promise.all(dimensions.map(([width, height]) =>
    sharp({ create: { width, height, channels: 3, background: '#dde8ee' } }).png().toBuffer()));
  const texts = [], images = [], frames = [];
  const originalText = PDFPage.prototype.drawText;
  const originalImage = PDFPage.prototype.drawImage;
  const originalRectangle = PDFPage.prototype.drawRectangle;
  PDFPage.prototype.drawText = function(text, options) {
    texts.push({ text, options, page: this });
    return originalText.call(this, text, options);
  };
  PDFPage.prototype.drawImage = function(image, options) {
    if (dimensions.some(([w, h]) => image.width === w && image.height === h)) images.push({ image, options, page: this });
    return originalImage.call(this, image, options);
  };
  PDFPage.prototype.drawRectangle = function(options) {
    if (options.borderColor && options.borderWidth === 0.55) frames.push({ options, page: this });
    return originalRectangle.call(this, options);
  };
  let result;
  try {
    result = await generateVisitReport({
      dossier: { id: 'synthetic-plan-preview', patient: { firstName: 'Anne', lastName: 'EXEMPLE' } },
      documents, recommendations: [],
      fetchImageBytes: async ({ id }) => ({ buffer: buffers[documents.findIndex(doc => doc.id === id) % buffers.length], mimeType: 'image/png' }),
    });
  } finally {
    PDFPage.prototype.drawText = originalText;
    PDFPage.prototype.drawImage = originalImage;
    PDFPage.prototype.drawRectangle = originalRectangle;
  }
  assert.equal(result.stats.planBeforePagesAdded, 2);
  assert.equal(result.stats.planAfterPagesAdded, 4);
  assert.equal(images.length, documents.length);
  const pages = [...new Set(images.map(image => image.page))];
  assert.equal(pages.length, 8);
  for (const page of pages) {
    assert.ok(images.filter(image => image.page === page).length <= 2);
    assert.ok(frames.some(frame => frame.page === page));
  }
  for (const doc of documents) {
    const caption = texts.find(text => text.text === doc.title);
    assert.ok(caption, `Missing caption for ${doc.id}`);
    const photo = images.find(image => image.page === caption.page &&
      image.options.y > caption.options.y && image.options.y - caption.options.y < 20);
    assert.ok(photo, 'Caption must sit directly below its image');
    assert.deepEqual(caption.options.color, { type: 'RGB', red: 0, green: 0, blue: 0 });
    assert.ok(Math.abs(photo.options.width / photo.options.height - photo.image.width / photo.image.height) < 1e-8);
  }
  assert.equal(texts.filter(t => t.text === 'Plan du logement avant travaux (suite)').length, 2);
  assert.equal(texts.filter(t => t.text === 'Plan des travaux préconisés (suite)').length, 4);
  assert.equal(texts.filter(t => t.text === 'Projet 1').length, 3);
  assert.equal(texts.filter(t => t.text === 'Projet 2').length, 2);
  const pdf = await PDFDocument.load(result.bytes);
  const numbers = texts.filter(t => /^\d+$/.test(t.text) && t.options.y === 14);
  assert.deepEqual(numbers.map(n => n.text), Array.from({ length: pdf.getPageCount() - 1 }, (_, i) => String(i + 1)));
  assert.equal(numbers.length, new Set(numbers.map(n => n.page)).size);
  if (process.env.PLAN_PREVIEW_PATH) await fs.writeFile(process.env.PLAN_PREVIEW_PATH, result.bytes);
});
