import sharp from 'sharp';

// 200 dpi at the printed size keeps product illustrations clear without
// embedding full camera-resolution images in the small recommendation slots.
const DPI = 200;

export async function optimizeRecommendationImage(image, rectangles = []) {
  if (!image?.buffer?.length) return image;
  const valid = rectangles.filter(rect => Number.isFinite(rect.width) && rect.width > 0
    && Number.isFinite(rect.height) && rect.height > 0);
  if (!valid.length) return image;
  const width = Math.ceil(Math.max(...valid.map(rect => rect.width)) * DPI / 72);
  const height = Math.ceil(Math.max(...valid.map(rect => rect.height)) * DPI / 72);
  try {
    const pipeline = sharp(image.buffer, { page: 0, limitInputPixels: 40_000_000 });
    const metadata = await pipeline.metadata();
    const buffer = await pipeline.rotate()
      .resize({ width, height, fit: 'inside', withoutEnlargement: true })
      .flatten({ background: '#ffffff' })
      .jpeg({ quality: 82, mozjpeg: true, chromaSubsampling: '4:4:4' })
      .toBuffer();
    // Avoid a second lossy encode when an existing JPEG is already compact
    // and fits the target. EXIF orientation must still be baked in when set.
    if (metadata.format === 'jpeg' && (!metadata.orientation || metadata.orientation === 1)
      && metadata.width <= width && metadata.height <= height
      && image.buffer.length <= buffer.length) return image;
    return { buffer, mimeType: 'image/jpeg' };
  } catch (error) {
    console.warn('[report] optimisation image préconisation impossible :', error?.message || error);
    // Preserve the existing embedding fallback, including for unusual formats.
    return image;
  }
}
