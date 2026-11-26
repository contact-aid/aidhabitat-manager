import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { gzipSync } from 'node:zlib';
import test from 'node:test';
import { readAndVerifyBackup } from './nocodbBackupLib.mjs';
import { scanBackupStream, verifyBackupStream } from './verify-nocodb-backup-stream.mjs';

const tricky = 'accolade } crochet ] { [ guillemet \\" antislash \\\\ "records":[ é ü 🙂';
const backup = {
  version: 1,
  createdAt: '2026-11-26T10:00:00.000Z',
  baseId: 'base_test',
  apiUrl: 'https://example.test',
  tables: [
    { id: 't1', name: 'Beneficiaires', fields: [{ id: 'f', name: 'nom', type: 'Text', required: false }],
      records: [{ Id: 1, nom: tricky, nested: { a: [1, { b: '}' }] } }, { Id: 2, nom: 'B' }] },
    { id: 't2', name: '📁 dossiers', fields: [], records: [{ Id: 1, note: '{"records":[]}' }] },
    { id: 't3', name: 'Mobile_documents', fields: [], records: [{ Id: 1, uuid_source: 'doc-1' }] },
    { id: 't4', name: 'Mobile_document_chunks', fields: [],
      records: [
        { Id: 1, document_uuid_source: 'doc-1', chunk_base64: 'A'.repeat(70_000) },
        { Id: 2, document_uuid_source: 'upload_x' },
        { Id: 3, document_uuid_source: 'missing' },
      ] },
    { id: 't5', name: 'Mobile_note_pages', fields: [], records: [] },
  ],
};

// Same layout as tools/backup-nocodb.mjs (one JSON.stringify per record).
const serialize = (data) => {
  let out = `{"version":1,"createdAt":${JSON.stringify(data.createdAt)},"baseId":${JSON.stringify(data.baseId)},"apiUrl":${JSON.stringify(data.apiUrl)},"tables":[`;
  data.tables.forEach((t, index) => {
    out += `${index ? ',' : ''}{"id":${JSON.stringify(t.id)},"name":${JSON.stringify(t.name)},"fields":${JSON.stringify(t.fields)},"records":[`;
    out += t.records.map((r) => JSON.stringify(r)).join(',');
    out += ']}';
  });
  return `${out}]}`;
};

test('streaming scan matches the full parse even when every chunk is tiny', async () => {
  const text = serialize(backup);
  assert.deepEqual(JSON.parse(text), backup);
  for (const size of [1, 2, 3, 7, 64, 4096]) {
    const pieces = [];
    for (let i = 0; i < text.length; i += size) pieces.push(text.slice(i, i + size));
    const seen = [];
    let root;
    await scanBackupStream(Readable.from(pieces), {
      onRoot: (header) => { root = header; },
      onTable: (header) => seen.push({ name: header.name, fields: header.fields, records: [] }),
      onRecord: (record) => seen.at(-1).records.push(record),
      onTableEnd: () => {},
    });
    assert.equal(root.baseId, 'base_test', `chunk size ${size}`);
    assert.deepEqual(seen.map((t) => ({ name: t.name, fields: t.fields, records: t.records })),
      backup.tables.map((t) => ({ name: t.name, fields: t.fields, records: t.records })), `chunk size ${size}`);
  }
});

test('file verification agrees with the in-memory verifier', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'verify-stream-'));
  try {
    const file = join(dir, 'aidhabitat-test.json.gz');
    await writeFile(file, gzipSync(serialize(backup)));
    const streamed = await verifyBackupStream(file);
    const full = await readAndVerifyBackup(file);
    assert.equal(streamed.ok, true);
    assert.equal(streamed.ok, full.ok);
    assert.deepEqual(streamed.failures, full.failures);
    assert.deepEqual(streamed.warnings, full.warnings);
    assert.equal(streamed.summary.records, full.summary.records);
    assert.equal(streamed.summary.orphanChunks, 1);
    assert.equal(streamed.summary.perTable.mobile_document_chunks, 3);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('truncated or empty critical tables are reported as failures', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'verify-stream-'));
  try {
    const text = serialize(backup);
    const truncated = join(dir, 'truncated.json.gz');
    await writeFile(truncated, gzipSync(text.slice(0, Math.floor(text.length * 0.6))));
    await assert.rejects(verifyBackupStream(truncated), /tronqué|JSON/);

    const emptyBeneficiaries = structuredClone(backup);
    emptyBeneficiaries.tables[0].records = [];
    const empty = join(dir, 'empty.json.gz');
    await writeFile(empty, gzipSync(serialize(emptyBeneficiaries)));
    const result = await verifyBackupStream(empty);
    assert.equal(result.ok, false);
    assert.match(result.failures.join(' '), /table critique vide: Beneficiaires/);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
