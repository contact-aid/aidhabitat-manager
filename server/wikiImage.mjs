import sharp from 'sharp';

// NocoDB LongText rejects values above 100,000 characters, including the
// data-URL prefix. Fit on the server so existing queued uploads can retry.
export const WIKI_IMAGE_MAX_CHARACTERS = 100_000;

export async function fitWikiImageDataUrl(value) {
  const url = String(value || '').trim();
  if (!url.startsWith('data:') || url.length <= WIKI_IMAGE_MAX_CHARACTERS) return url;
  const match = url.match(/^data:image\/(?:jpeg|png|webp|gif);base64,(.+)$/);
  if (!match) throw new Error('Format d’image invalide');
  const input = Buffer.from(match[1], 'base64');
  for (const size of [1024, 800, 640, 480, 320, 160]) {
    const buffer = await sharp(input, { limitInputPixels: 40_000_000 })
      .rotate()
      .resize({ width: size, height: size, fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .jpeg({ quality: 75, mozjpeg: true })
      .toBuffer();
    const result = `data:image/jpeg;base64,${buffer.toString('base64')}`;
    if (result.length <= WIKI_IMAGE_MAX_CHARACTERS) return result;
  }
  throw new Error('Image trop volumineuse pour la bibliothèque');
}
