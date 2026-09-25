import assert from 'node:assert/strict';
import test from 'node:test';
import { PDFDocument } from 'pdf-lib';
import sharp from 'sharp';
import { generateVisitReport } from './reports/generateVisitReport.mjs';

test('four recommendations keep their images in JPEG, WebP, PNG and GIF', async () => {
  const source = sharp({
    create: {
      width: 24,
      height: 24,
      channels: 3,
      background: '#ef713e',
    },
  });
  const images = await Promise.all([
    source.clone().jpeg().toBuffer(),
    source.clone().webp().toBuffer(),
    source.clone().png().toBuffer(),
    source.clone().gif().toBuffer(),
  ]);
  const recommendations = images.map((_, index) => ({
    wikiTitle: `Préconisation ${index + 1}`,
    wikiImageUrl: `image-${index + 1}`,
    note: `Argumentaire ${index + 1}`,
  }));
  const { bytes, stats } = await generateVisitReport({
    dossier: {
      id: 'four-images',
      patient: { firstName: 'Test', lastName: 'Images' },
      housing: {},
    },
    recommendations,
    documents: [],
    notePages: [],
    fetchImageBytes: async ({ url }) => ({
      buffer: images[Number(url.split('-').at(-1)) - 1],
      mimeType: 'application/octet-stream',
    }),
  });

  assert.equal(stats.recoTextApplied, 4);
  assert.equal(stats.imagesApplied, 4);
  assert.equal(stats.imagesMissingField, 0);
  assert.equal(stats.imagesMissingValue, 0);
  assert.equal(stats.imagesFailedEmbed, 0);
  assert.ok((await PDFDocument.load(bytes)).getPageCount() > 10);
});
