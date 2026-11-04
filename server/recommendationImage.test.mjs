import assert from 'node:assert/strict';
import test from 'node:test';
import sharp from 'sharp';
import { optimizeRecommendationImage } from './reports/recommendationImage.mjs';

const slot = [{ width: 144, height: 108 }]; // 2 x 1.5 inches, 400 x 300 px at 200 dpi.

test('large illustrations shrink substantially and retain their aspect ratio', async () => {
  const pixels = Buffer.alloc(1600 * 1200 * 3);
  let seed = 42;
  for (let i = 0; i < pixels.length; i++) {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    pixels[i] = seed >>> 24;
  }
  for (const format of ['jpeg', 'png', 'webp']) {
    const buffer = await sharp(pixels, { raw: { width: 1600, height: 1200, channels: 3 } })
      [format]().toBuffer();
    const original = Buffer.from(buffer);
    const result = await optimizeRecommendationImage({ buffer, mimeType: `image/${format}` }, slot);
    const metadata = await sharp(result.buffer).metadata();
    assert.equal(result.mimeType, 'image/jpeg');
    assert.equal(metadata.width, 400);
    assert.equal(metadata.height, 300);
    assert.ok(result.buffer.length < buffer.length / 4, format);
    assert.deepEqual(buffer, original);
  }
});

test('small transparent illustrations stay small and use a white background', async () => {
  const buffer = await sharp({ create: { width: 80, height: 40, channels: 4,
    background: { r: 0, g: 0, b: 0, alpha: 0 } } }).png().toBuffer();
  const result = await optimizeRecommendationImage({ buffer }, slot);
  const { data, info } = await sharp(result.buffer).raw().toBuffer({ resolveWithObject: true });
  assert.equal(info.width, 80);
  assert.equal(info.height, 40);
  assert.deepEqual([...data.subarray(0, 3)], [255, 255, 255]);
});

test('EXIF rotation is preserved and compact JPEGs avoid unnecessary re-encoding', async () => {
  const buffer = await sharp({ create: { width: 80, height: 40, channels: 3,
    background: '#ef713e' } }).jpeg({ quality: 40 }).toBuffer();
  const image = { buffer, mimeType: 'image/jpeg' };
  assert.equal(await optimizeRecommendationImage(image, slot), image);
  const rotated = await sharp(buffer).withMetadata({ orientation: 6 }).toBuffer();
  const result = await optimizeRecommendationImage({ buffer: rotated }, slot);
  const metadata = await sharp(result.buffer).metadata();
  assert.equal(metadata.width, 40);
  assert.equal(metadata.height, 80);
  assert.equal(metadata.orientation, undefined);
});

test('missing rectangles or unsupported bytes preserve the existing fallback', async () => {
  const image = { buffer: Buffer.from('not an image'), mimeType: 'image/jpeg' };
  assert.equal(await optimizeRecommendationImage(image), image);
  assert.equal(await optimizeRecommendationImage(image, slot), image);
});
