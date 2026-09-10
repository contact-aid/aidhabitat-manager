import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { setImmediate } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

if (process.argv.includes('--agent4-report-runner')) {
  await runReportRoute();
} else {
  test('real report route never treats an incomplete inline list as deletion intent', {
    timeout: 60000,
  }, async (t) => {
    const root = await mkdtemp(path.join(tmpdir(), 'aidhabitat-agent4-report-'));
    try {
      const { stdout, stderr } = await promisify(execFile)(process.execPath, [
        fileURLToPath(import.meta.url),
        '--agent4-report-runner',
      ], {
        cwd: root,
        env: {
          NODE_ENV: 'test',
          AIDHABITAT_API_ONLY: '1',
          AIDHABITAT_DATA_DIR_PATH: root,
          AUTH_SESSION_SECRET: 'synthetic-agent4-report-session-secret',
          NOCODB_API_URL: 'https://nocodb.test.invalid',
          NOCODB_API_TOKEN: 'synthetic-conditional-http-token',
          NOCODB_BASE_ID: 'conditional_http_base',
          NOCODB_FORCE_REST: '1',
          NOCODB_REST_TIMEOUT_MS: '5000',
        },
        timeout: 55000,
        maxBuffer: 300000,
      });
      assert.match(stdout, /AGENT4_REPORT_ROUTE_PASS/);
      t.diagnostic(
        stdout
          .split('\n')
          .filter((line) => /^(PASS |AGENT4_REPORT_ROUTE_PASS)/.test(line))
          .join('\n'),
      );
      if (stderr.trim()) t.diagnostic(stderr.trim());
    } catch (error) {
      assert.fail(
        `Report HTTP integration failed\n${error.stdout || ''}\n${error.stderr || error.message}`,
      );
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
}

async function runReportRoute() {
  const {
    createRestMock,
    dossierId,
    ownerEmail,
    password,
    tables,
  } = await import('./test-fixtures/conditionalRoutes.rest.mjs');
  const base = createRestMock();
  const patientId = 'nocodb-beneficiaire-201';
  const png = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    'base64',
  );
  const documents = [
    documentRow(501, 'remote-photo-a', 'local-photo-a', ['Visite - Logement'], png),
    documentRow(502, 'remote-photo-b', 'local-photo-b', ['Visite - Sanitaires'], png),
    documentRow(503, 'remote-contract', 'local-contract', ['Mandat'], Buffer.from('synthetic text')),
  ];
  const deletes = [];
  const contentReads = [];
  let nextId = 600;
  let nextAuxiliaryId = 1000;
  let apiOrigin;
  const nativeFetch = globalThis.fetch;
  const emptyReportTables = new Set([
    tables.mobile_document_chunks,
    tables.mobile_note_pages,
    tables.mobile_visit_recommendations,
    'mdukulxcd18ae3o',
    'mbkuomk0aazes1c',
    'mbaj91z97utreco',
    'mfeu4lijbge4opz',
    'm34ho32msfz8b2x',
    'mt36dqp3ybw5dtt',
  ]);

  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : input);
    if (apiOrigin && url.origin === apiOrigin) {
      return nativeFetch(input, { ...init, redirect: 'error' });
    }
    const records = /^\/api\/v2\/tables\/([^/]+)\/records$/.exec(url.pathname);
    if (!records) return base.fetch(input, init);

    assert.equal(url.origin, 'https://nocodb.test.invalid');
    assert.equal(
      new Headers(init.headers).get('xc-token'),
      'synthetic-conditional-http-token',
    );
    const method = init.method || 'GET';
    const tableId = records[1];
    if (emptyReportTables.has(tableId)) {
      if (method === 'GET') {
        return json({ list: [], pageInfo: { totalRows: 0, isLastPage: true } });
      }
      if (method === 'POST') {
        const body = JSON.parse(init.body);
        if (Array.isArray(body)) {
          return json(body.map((row) => ({ Id: nextAuxiliaryId++, ...row })), 201);
        }
        return json({ Id: nextAuxiliaryId++, ...body }, 201);
      }
      if (method === 'PATCH') return json(JSON.parse(init.body));
      if (method === 'DELETE') return json(JSON.parse(init.body));
      assert.fail(`Unexpected auxiliary method ${method} for ${tableId}`);
    }
    if (!Object.values(tables).includes(tableId)) {
      assert.equal(method, 'GET', `unexpected write to report lookup table ${tableId}`);
      return json({ list: [], pageInfo: { totalRows: 0, isLastPage: true } });
    }
    if (tableId !== tables.mobile_documents) return base.fetch(input, init);
    if (method === 'GET') {
      let list = structuredClone(documents);
      const where = url.searchParams.get('where') || '';
      for (const key of [
        'beneficiaire_id',
        'dossier_id',
        'uuid_source',
        'client_document_id',
      ]) {
        const match = new RegExp(`\\(${key},eq,\\"?([^\\"()]+)\\"?\\)`).exec(where);
        if (match) list = list.filter((row) => String(row[key]) === match[1]);
      }
      if (/\(uuid_source,eq,/.test(where) && list.length === 1) {
        contentReads.push(list[0].uuid_source);
      }
      const fields = url.searchParams.get('fields')?.split(',');
      if (fields) {
        list = list.map((row) =>
          Object.fromEntries(fields.map((key) => [key, row[key] ?? null])),
        );
      }
      return json({
        list,
        pageInfo: { totalRows: list.length, isLastPage: true },
      });
    }
    if (method === 'POST') {
      const body = JSON.parse(init.body);
      const created = { Id: nextId++, ...body };
      documents.push(created);
      return json(created, 201);
    }
    if (method === 'PATCH') {
      const patches = JSON.parse(init.body);
      for (const patch of patches) {
        const row = documents.find((item) => item.Id === patch.Id);
        assert(row, `Unknown document PATCH ${patch.Id}`);
        Object.assign(row, patch);
      }
      return json(patches);
    }
    if (method === 'DELETE') {
      const { Id } = JSON.parse(init.body);
      deletes.push(Id);
      const index = documents.findIndex((item) => item.Id === Id);
      if (index >= 0) documents.splice(index, 1);
      return json({ Id });
    }
    assert.fail(`Unexpected document method ${method}`);
  };

  const { default: app } = await import('./index.mjs');
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  apiOrigin = `http://127.0.0.1:${server.address().port}`;
  try {
    await setImmediate();
    const login = await fetch(`${apiOrigin}/api/auth/login`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ email: ownerEmail, password }),
    });
    assert.equal(login.status, 200);
    const token = (await login.json()).data.token;

    const form = new FormData();
    form.append('inline_doc_local-photo-a', new Blob([png], { type: 'image/png' }), 'photo-a.png');
    form.append(
      'inline_doc_local-photo-a_meta',
      JSON.stringify({
        fileName: 'photo-a.png',
        mimeType: 'image/png',
        tags: ['Visite - Logement'],
        dossierId,
        title: 'Photo A inline',
      }),
    );
    form.append(
      'inline_doc_order',
      JSON.stringify([{ id: 'local-photo-a', categoryOrder: 0 }]),
    );
    const response = await fetch(`${apiOrigin}/api/reports/visit/${dossierId}`, {
      method: 'POST',
      headers: { 'x-app-session': token },
      body: form,
      signal: AbortSignal.timeout(40000),
    });
    const responseBytes = Buffer.from(await response.arrayBuffer());
    assert.equal(response.status, 200, responseBytes.toString('utf8').slice(0, 500));
    assert.match(response.headers.get('content-type') || '', /application\/pdf/);
    assert(responseBytes.subarray(0, 4).equals(Buffer.from('%PDF')));

    // The inline copy is preferred, while the other remote visit photo is fetched.
    assert(!contentReads.includes('remote-photo-a'));
    assert(contentReads.includes('remote-photo-b'));
    assert(!contentReads.includes('remote-contract'));
    await setImmediate();
    await setImmediate();
    assert.deepEqual(base.violations, []);
    assert.deepEqual(
      deletes,
      [],
      'report generation must never infer document deletion from omitted inline assets',
    );
    for (const id of ['remote-photo-a', 'remote-photo-b', 'remote-contract']) {
      assert(documents.some((row) => row.uuid_source === id), `${id} was preserved`);
    }
    console.log('PASS report: inline A + remote B + non-photo preserved, zero DELETE');
    console.log('AGENT4_REPORT_ROUTE_PASS');
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
    globalThis.fetch = nativeFetch;
  }
}

function documentRow(Id, uuid, clientId, tags, content) {
  return {
    Id,
    uuid_source: uuid,
    beneficiaire_id: 'nocodb-beneficiaire-201',
    dossier_id: '22222222-2222-4222-8222-222222222222',
    beneficiaire_prenom: 'Synthetic',
    beneficiaire_nom: 'Patient',
    beneficiaire_nom_complet: 'Synthetic Patient',
    dossier_libelle: 'Synthetic Patient',
    client_document_id: clientId,
    titre: uuid,
    nom_fichier: `${uuid}.png`,
    mime_type: 'image/png',
    tags_json: JSON.stringify(tags),
    contenu_base64: content.toString('base64'),
    created_at: '2026-09-01T10:00:00.000Z',
    updated_at: '2026-09-01T10:00:00.000Z',
  };
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}
