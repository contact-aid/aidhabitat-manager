import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { normalize, photoMetadata } from './precoPhotoCatalog.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [mode, source, output] = process.argv.slice(2);
if (!['prepare', 'optimize', 'apply', 'verify'].includes(mode) || !source || !output) {
  throw Error('Usage: node tools/import-preco-photos.mjs prepare|optimize|apply|verify SOURCE OUTPUT');
}
const out = path.resolve(output);
if (out === root || out === path.resolve(source)) throw Error('Use a separate output directory');
const env = { ...dotenv.parse(await fs.readFile(path.join(root, '.env.local'))), ...process.env };
if (env.NOCODB_BASE_ID !== 'pskgbjythubfzv9') throw Error('Unexpected target base');
const base = env.NOCODB_API_URL.replace(/\/$/, '');
async function request(route, body) {
  const response = await fetch(`${base}${route}`, {
    method: body ? 'POST' : 'GET',
    headers: { 'xc-token': env.NOCODB_API_TOKEN, 'Content-Type': 'application/json' },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) {
    const error = await response.json().catch(() => ({}));
    const detail = String(error.msg ?? error.message ?? error.error ?? '').replace(/[A-Za-z0-9+/=]{100,}/g, '[redacted]').slice(0, 400);
    throw Error(`NocoDB ${body ? 'POST' : 'GET'} HTTP ${response.status}: ${detail}`);
  }
  return response.json();
}
const tables = (await request(`/api/v2/meta/bases/${env.NOCODB_BASE_ID}/tables`)).list;
const table = tables.find(t => t.title === 'Wiki_table')?.id;
const tagsTable = tables.find(t => t.title === 'Wiki_tags')?.id;
if (!table || !tagsTable) throw Error('Missing wiki tables');
async function readAll(id) {
  const rows = [];
  for (let offset = 0; ; offset += 100) {
    const page = await request(`/api/v2/tables/${id}/records?limit=100&offset=${offset}`);
    if (!Array.isArray(page.list)) throw Error('Invalid record response');
    rows.push(...page.list);
    if (page.pageInfo?.isLastPage || page.list.length < 100) return rows;
  }
}
const rows = await readAll(table);
const tags = await readAll(tagsTable);
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const same = (row, fields) => Object.entries(fields).every(([k, v]) => row[k] === v);
const planPath = path.join(out, 'plan.json');

if (mode === 'prepare') {
  await fs.mkdir(out, { recursive: true });
  const original = JSON.stringify({ baseId: env.NOCODB_BASE_ID, table, rows, tags }, null, 2);
  await fs.writeFile(path.join(out, 'before.json'), original, { flag: 'wx', mode: 0o600 });
  const legacy = JSON.parse(await fs.readFile(path.join(root, 'public/wiki-offline/preco-illustrations/manifest.json'))).items;
  const files = execFileSync('rg', ['--files'], { cwd: source, encoding: 'utf8' }).trim().split('\n').sort();
  const used = new Set();
  const items = [];
  let originalBytes = 0;
  let importedBytes = 0;
  await fs.mkdir(path.join(out, 'images'), { recursive: true });
  for (const file of files) {
    if (!/\.(png|jpe?g)$/i.test(file)) throw Error(`Unexpected file ${file}`);
    const meta = photoMetadata(file);
    const id = `preco-photo-${sha(file.normalize('NFC')).slice(0, 24)}`;
    const originalFile = path.join(source, file);
    const bytes = await fs.readFile(originalFile);
    originalBytes += bytes.length;
    const candidates = legacy.filter(x => normalize(path.basename(x.source)) === normalize(path.basename(file)));
    const existing = rows.find(r => !used.has(r.uuid_source) && candidates.some(x => x.publicPath === r.photos));
    if (existing) {
      used.add(existing.uuid_source);
      items.push({ source: file.normalize('NFC'), sourceSha256: sha(bytes), action: 'preserve', id: existing.uuid_source, title: existing.titre });
      continue;
    }
    const target = path.join(out, 'images', `${id}.jpg`);
    // Generate delivery copies only; the user's originals are never changed.
    const dimensions = execFileSync('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', originalFile], { encoding: 'utf8', timeout: 20000 });
    const width = Number(dimensions.match(/pixelWidth: (\d+)/)?.[1]);
    const height = Number(dimensions.match(/pixelHeight: (\d+)/)?.[1]);
    if (!width || !height) throw Error(`Undecodable image ${file}`);
    const resize = Math.max(width, height) > 1400 ? ['-Z', '1400'] : [];
    execFileSync('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', 'normal', ...resize, originalFile, '--out', target], { stdio: 'pipe', timeout: 20000 });
    if (bytes[0] === 0xff && bytes[1] === 0xd8 && !resize.length && bytes.length < (await fs.stat(target)).size) {
      await fs.copyFile(originalFile, target);
    }
    const image = await fs.readFile(target);
    if (image[0] !== 0xff || image[1] !== 0xd8 || image.length < 100) throw Error(`Invalid JPEG ${file}`);
    importedBytes += image.length;
    const tag = tags.find(t => t.tags === meta.tags[0]);
    if (!tag) throw Error(`Missing tag ${meta.tags[0]}`);
    items.push({ source: file.normalize('NFC'), sourceSha256: sha(bytes), action: 'create', id, ...meta,
      imageFile: `images/${id}.jpg`, imageSha256: sha(image), imageBytes: image.length, tagId: tag.Id });
    if (items.length % 25 === 0) console.log(`Prepared ${items.length}/${files.length}`);
  }
  if (new Set(items.map(x => x.id)).size !== items.length) throw Error('Duplicate identities');
  const plan = { version: 1, baseId: env.NOCODB_BASE_ID, table, beforeSha256: sha(original), originalBytes, importedBytes, items };
  await fs.writeFile(planPath, JSON.stringify(plan, null, 2), { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ files: items.length, preserve: items.filter(x => x.action === 'preserve').length, create: items.filter(x => x.action === 'create').length, originalBytes, importedBytes }));
} else if (mode === 'optimize') {
  const plan = JSON.parse(await fs.readFile(planPath));
  for (const item of plan.items.filter(x => x.action === 'create' && x.imageBytes > 74000)) {
    if (rows.some(r => r.uuid_source === item.id)) throw Error(`Do not alter confirmed image ${item.id}`);
    // Work from the original for every trial to avoid cumulative compression.
    const original = path.join(source, item.source);
    if (sha(await fs.readFile(original)) !== item.sourceSha256) throw Error('Source changed');
    const target = path.join(out, item.imageFile);
    const dimensions = execFileSync('/usr/bin/sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', original], { encoding: 'utf8', timeout: 20000 });
    const edge = Math.max(Number(dimensions.match(/pixelWidth: (\d+)/)?.[1]), Number(dimensions.match(/pixelHeight: (\d+)/)?.[1]));
    let image;
    for (const max of [1200, 1000, 850, 700, 600, 500]) {
      const resize = edge > max ? ['-Z', String(max)] : [];
      execFileSync('/usr/bin/sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', 'low', ...resize, original, '--out', target], { stdio: 'pipe', timeout: 20000 });
      image = await fs.readFile(target);
      if (image.length <= 74000) break;
    }
    if (!image || image.length > 74000) throw Error(`Image still too large: ${item.source}`);
    item.imageBytes = image.length;
    item.imageSha256 = sha(image);
  }
  plan.importedBytes = plan.items.reduce((sum, x) => sum + (x.imageBytes ?? 0), 0);
  await fs.writeFile(planPath, JSON.stringify(plan, null, 2));
  console.log(JSON.stringify({ importedBytes: plan.importedBytes, maxImageBytes: Math.max(...plan.items.map(x => x.imageBytes ?? 0)) }));
} else {
  const plan = JSON.parse(await fs.readFile(planPath));
  const beforeText = await fs.readFile(path.join(out, 'before.json'), 'utf8');
  if (sha(beforeText) !== plan.beforeSha256 || table !== plan.table || env.NOCODB_BASE_ID !== plan.baseId) throw Error('Plan target/backup mismatch');
  const before = JSON.parse(beforeText);
  const lock = await fs.open(path.join(out, '.lock'), 'wx');
  const fieldsFor = async item => {
    const image = await fs.readFile(path.join(out, item.imageFile));
    if (sha(image) !== item.imageSha256) throw Error(`Image changed: ${item.source}`);
    const photo = `data:image/jpeg;base64,${image.toString('base64')}`;
    if (photo.length > 100000) throw Error(`Image exceeds NocoDB LongText limit: ${item.source}`);
    return { uuid_source: item.id, titre: item.title, photos: '', photo_base64: photo,
      contenu: JSON.stringify({ description: item.description, category: item.category, tags: item.tags }), wiki_tags_id: item.tagId };
  };
  try {
    if (mode === 'apply') {
      // Validate the entire plan before the first write. No UPDATE or DELETE.
      for (const item of plan.items.filter(x => x.action === 'create')) {
        const fields = await fieldsFor(item);
        const matches = rows.filter(r => r.uuid_source === item.id);
        if (matches.length > 1 || (matches.length === 1 && !same(matches[0], fields))) throw Error(`Existing import differs: ${item.id}`);
      }
      let created = 0;
      for (const item of plan.items.filter(x => x.action === 'create')) {
        if (rows.some(r => r.uuid_source === item.id)) continue;
        const fields = await fieldsFor(item);
        let failure;
        try { await request(`/api/v2/tables/${table}/records`, fields); } catch (e) { failure = e; }
        const where = encodeURIComponent(`(uuid_source,eq,${item.id})`);
        const confirmed = (await request(`/api/v2/tables/${table}/records?where=${where}&limit=2`)).list;
        if (confirmed?.length !== 1 || !same(confirmed[0], fields)) throw failure ?? Error(`Unconfirmed create ${item.id}`);
        await fs.appendFile(path.join(out, 'created.ndjson'), JSON.stringify({ id: item.id, recordId: confirmed[0].Id }) + '\n', { mode: 0o600 });
        created++;
        if (created % 20 === 0) console.log(`Created and verified ${created}`);
      }
    }
    const after = await readAll(table);
    for (const item of plan.items) {
      const matches = after.filter(r => r.uuid_source === item.id);
      if (matches.length !== 1) throw Error(`Missing/duplicate item ${item.id}`);
      if (item.action === 'create' && !same(matches[0], await fieldsFor(item))) throw Error(`Content mismatch ${item.id}`);
    }
    for (const old of before.rows) {
      const current = after.find(r => r.Id === old.Id);
      const stable = Object.fromEntries(['uuid_source', 'titre', 'photos', 'photo_base64', 'contenu', 'wiki_tags_id'].map(k => [k, old[k]]));
      if (!current || !same(current, stable)) throw Error(`Preexisting row changed: ${old.Id}`);
    }
    const report = { verifiedAt: new Date().toISOString(), sourcePhotos: plan.items.length, beforeRows: before.rows.length, afterRows: after.length, imported: plan.items.filter(x => x.action === 'create').length, existingRowsUnchanged: true };
    await fs.writeFile(path.join(out, 'verification.json'), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report));
  } finally {
    await lock.close();
    await fs.unlink(path.join(out, '.lock'));
  }
}
