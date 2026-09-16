import assert from 'node:assert/strict';
import test from 'node:test';
import { uniformPhotoHeight } from './reports/photoLayout.mjs';
import { PDFPage, PDFDocument } from 'pdf-lib';
import UPNG from '@pdf-lib/upng';
import fs from 'node:fs/promises';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

const slot = (width, w, h) => ({ width, image: { width: w, height: h } });
test('portrait, landscape and square photos share a contained height', () => {
  const slots = [slot(120, 600, 900), slot(260, 1600, 900), slot(120, 900, 900)];
  const height = uniformPhotoHeight(slots, 200);
  assert.equal(height, 120);
  for (const s of slots) {
    const drawnWidth = height * s.image.width / s.image.height;
    assert.ok(drawnWidth <= s.width + 1e-8);
    assert.equal(Math.min(height, s.width * s.image.height / s.image.width), height);
    assert.ok(Math.abs(drawnWidth / height - s.image.width / s.image.height) < 1e-8);
  }
});
test('shared height is independent of category, order or continuation page', () => {
  const slots = [slot(120, 600, 900), slot(260, 2400, 600), slot(260, 900, 600)];
  assert.equal(uniformPhotoHeight(slots, 200), 65);
  assert.equal(uniformPhotoHeight([...slots].reverse(), 200), 65);
});
test('portrait-only and empty sections retain preferred height when possible', () => {
  assert.equal(uniformPhotoHeight([slot(120, 400, 900)], 200), 200);
  assert.equal(uniformPhotoHeight([], 200), 200);
});
test('invalid image dimensions are rejected', () => {
  assert.throws(() => uniformPhotoHeight([slot(120, 0, 100)], 200), RangeError);
});

test('real report renders all photos at the same height across pages', async () => {
  const dimensions = [[80, 120], [160, 90], [100, 100], [240, 60]];
  const images = dimensions.map(([w, h], index) => {
    const rgba = new Uint8Array(w * h * 4);
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
      const offset = (y * w + x) * 4;
      const border = x < 3 || y < 3 || x >= w - 3 || y >= h - 3;
      rgba.set(border ? [20, 20, 20, 255] :
        [70 + index * 35, 150, 210 - index * 30, 255], offset);
    }
    return Buffer.from(UPNG.default.encode([rgba.buffer], w, h, 0));
  });
  const documents = Array.from({ length: 28 }, (_, i) => ({
    id: `synthetic-photo-${i}`, title: `Photo ${i + 1}`,
    tags: [['Visite - Logement', 'Visite - Accessibilité', 'Visite - Sanitaires'][Math.floor(i / 10)]],
    categoryOrder: i, createdAt: '2026-01-01',
  }));
  const draws = [];
  const original = PDFPage.prototype.drawImage;
  PDFPage.prototype.drawImage = function (image, options) {
    if (dimensions.some(([w, h]) => image.width === w && image.height === h)) {
      draws.push({ image, options, page: this });
    }
    return original.call(this, image, options);
  };
  let result;
  try {
    result = await generateVisitReport({
      dossier: { id: 'synthetic', patient: { firstName: 'Test', lastName: 'Photos' } },
      sanitaires: {}, observations: {}, documents, notePages: [],
      contexteNotes: [], recommendations: [],
      ergoProfile: { displayName: 'Ergo Test', email: 'ergo@example.test' },
      fetchImageBytes: async ({ id }) => ({
        buffer: images[Number(id.split('-').at(-1)) % images.length], mimeType: 'image/png',
      }),
    });
  } finally {
    PDFPage.prototype.drawImage = original;
  }
  assert.equal(draws.length, documents.length);
  assert.ok(new Set(draws.map((d) => d.page)).size > 1);
  for (const { image, options, page } of draws) {
    assert.ok(Math.abs(options.height - draws[0].options.height) < 1e-7);
    assert.ok(Math.abs(options.width / options.height - image.width / image.height) < 1e-7);
    assert.ok(options.x >= 0 && options.x + options.width <= page.getWidth());
    assert.ok(options.y >= 40 && options.y + options.height <= page.getHeight());
  }
  assert.ok((await PDFDocument.load(result.bytes)).getPageCount() > 0);
  if (process.env.PDF_LAYOUT_PREVIEW) await fs.writeFile(process.env.PDF_LAYOUT_PREVIEW, result.bytes);
});
