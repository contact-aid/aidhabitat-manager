import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { readLocalWikiReportImage } from './reports/localWikiReportImage.mjs';

test('report reads authenticated wiki uploads from disk', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'wiki-report-'));
  try {
    const uploadsDir = path.join(root, 'uploads');
    await fs.mkdir(uploadsDir);
    await fs.writeFile(path.join(uploadsDir, 'door.png'), Buffer.from('image-data'));
    const options = { offlineDir: path.join(root, 'offline'), uploadsDir };
    const result = await readLocalWikiReportImage(
      'https://api.aidhabitat.fr/uploads/wiki-library/door.png', options,
    );
    assert.equal(result.buffer.toString(), 'image-data');
    assert.equal(result.mimeType, 'image/png');
    assert.equal(await readLocalWikiReportImage(
      'https://api.aidhabitat.fr/uploads/wiki-library/%2e%2e/private.png', options,
    ), null);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
