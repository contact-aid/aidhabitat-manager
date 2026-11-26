import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const script = fileURLToPath(new URL('./create-sync-archive-table.mjs', import.meta.url));
const run = promisify(execFile);

async function fakeNocodb() {
  const tables = [{ id: 'mexisting', title: 'Beneficiaires', columns: [] }];
  const posts = [];
  const server = createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    const send = (status, value) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(value)); };
    if (req.headers['xc-token'] !== 'synthetic-token') return send(401, {});
    if (req.method === 'GET' && req.url === '/api/v2/meta/bases/base1/tables') {
      return send(200, { list: tables.map(({ id, title }) => ({ id, title })) });
    }
    if (req.method === 'POST' && req.url === '/api/v2/meta/bases/base1/tables') {
      const payload = JSON.parse(body);
      posts.push(payload);
      tables.push({ id: 'marchive', title: payload.title, columns: payload.columns });
      return send(200, { id: 'marchive' });
    }
    const meta = /^\/api\/v2\/meta\/tables\/(\w+)$/.exec(req.url);
    if (req.method === 'GET' && meta) {
      const table = tables.find((t) => t.id === meta[1]);
      return table ? send(200, { id: table.id, columns: table.columns }) : send(404, {});
    }
    return send(404, {});
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return { server, posts, url: `http://127.0.0.1:${server.address().port}` };
}

test('read-only by default, creates once with --apply, then reports a conforming table', async () => {
  const nocodb = await fakeNocodb();
  const env = { ...process.env, NOCODB_API_URL: nocodb.url, NOCODB_API_TOKEN: 'synthetic-token', NOCODB_BASE_ID: 'base1' };
  try {
    const dry = await run(process.execPath, [script], { env });
    assert.match(dry.stdout, /absente/);
    assert.match(dry.stdout, /Lecture seule/);
    assert.equal(nocodb.posts.length, 0, 'nothing created without --apply');

    const created = await run(process.execPath, [script, '--apply'], { env });
    assert.match(created.stdout, /CREATION OK/);
    assert.equal(nocodb.posts.length, 1);
    const titles = nocodb.posts[0].columns.map((c) => c.title);
    for (const name of ['uuid_source', 'archived_at', 'field_name', 'previous_value', 'next_value', 'base_known', 'actor']) {
      assert(titles.includes(name), `column ${name}`);
    }

    const again = await run(process.execPath, [script, '--apply'], { env });
    assert.match(again.stdout, /Schéma conforme/);
    assert.equal(nocodb.posts.length, 1, 'never recreated');
  } finally {
    nocodb.server.close();
  }
});
