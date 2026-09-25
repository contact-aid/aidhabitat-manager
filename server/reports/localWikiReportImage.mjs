import fs from 'node:fs/promises';
import path from 'node:path';

const mimeByExtension = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
  '.webp': 'image/webp', '.gif': 'image/gif', '.svg': 'image/svg+xml',
};

/** Read wiki files directly because their public upload route requires a user session. */
export async function readLocalWikiReportImage(urlValue, { offlineDir, uploadsDir }) {
  const raw = String(urlValue || '').trim();
  if (!raw) return null;
  let pathname;
  try {
    pathname = decodeURIComponent(new URL(raw, 'https://aid-habitat.local').pathname);
  } catch {
    return null;
  }
  const source = pathname.startsWith('/wiki-offline/')
    ? { prefix: '/wiki-offline/', root: offlineDir }
    : pathname.startsWith('/uploads/wiki-library/')
      ? { prefix: '/uploads/wiki-library/', root: uploadsDir }
      : null;
  if (!source) return null;
  const relative = pathname.slice(source.prefix.length);
  if (!relative || relative.includes('\0')) return null;
  const resolvedRoot = path.resolve(source.root);
  const fullPath = path.resolve(resolvedRoot, relative);
  if (fullPath === resolvedRoot || !fullPath.startsWith(`${resolvedRoot}${path.sep}`)) return null;
  try {
    const buffer = await fs.readFile(fullPath);
    return { buffer, mimeType: mimeByExtension[path.extname(fullPath).toLowerCase()] || 'application/octet-stream' };
  } catch (error) {
    if (error?.code === 'ENOENT') return null;
    throw error;
  }
}
