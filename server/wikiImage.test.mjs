import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import sharp from 'sharp';
import { fitWikiImageDataUrl, WIKI_IMAGE_MAX_CHARACTERS } from './wikiImage.mjs';

test('fits a detailed image under the actual NocoDB field limit', async () => {
  const buffer = await sharp(randomBytes(1024 * 1024 * 3), {
    raw: { width: 1024, height: 1024, channels: 3 },
  }).png().toBuffer();
  const source = `data:image/png;base64,${buffer.toString('base64')}`;
  const result = await fitWikiImageDataUrl(source);
  assert.ok(source.length > WIKI_IMAGE_MAX_CHARACTERS);
  assert.ok(result.length <= WIKI_IMAGE_MAX_CHARACTERS);
  const metadata = await sharp(Buffer.from(result.split(',')[1], 'base64')).metadata();
  assert.equal(metadata.format, 'jpeg');
  assert.ok(metadata.width >= 320);
  assert.equal(await fitWikiImageDataUrl(result), result);
});

test('preserves small images and existing URLs exactly', async () => {
  for (const url of ['', '/wiki-access.svg', 'https://example.test/photo.png', 'data:image/png;base64,aGVsbG8=']) {
    assert.equal(await fitWikiImageDataUrl(url), url);
  }
});

test('rejects corrupt oversized image data without returning a false success', async () => {
  await assert.rejects(fitWikiImageDataUrl(`data:image/png;base64,${'x'.repeat(110_000)}`));
});
