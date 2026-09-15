import { readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.resolve(process.argv[2] || fileURLToPath(new URL('../../build/web', import.meta.url)));
const assets = [];
async function walk(dir) {
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) { await walk(file); continue; }
    const relative = path.relative(root, file).split(path.sep).join('/');
    if (relative.startsWith('.') || ['ai_offline_worker.js', 'release.json'].includes(relative)) continue;
    const bytes = await readFile(file);
    assets.push({path: relative, sha256: createHash('sha256').update(bytes).digest('hex')});
  }
}
await walk(root);
assets.sort((a,b) => a.path.localeCompare(b.path));
const build = createHash('sha256').update(JSON.stringify(assets)).digest('hex');
const template = await readFile(new URL('offline-worker.template.js', import.meta.url), 'utf8');
await writeFile(path.join(root, 'ai_offline_worker.js'), template
  .replace('__BUILD__', JSON.stringify(build)).replace('__ASSETS__', JSON.stringify(assets)));
console.log(`Offline static shell: ${assets.length} assets, ${build}`);
