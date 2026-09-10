import assert from 'node:assert/strict';
import test from 'node:test';
import { PassThrough } from 'node:stream';
import { mkdtemp, readdir, rm, stat } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import multer from 'multer';
import nodemailer from 'nodemailer';
import express from 'express';
import qs from 'qs';
import Ajv from 'ajv';
import { Hono } from 'hono';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';

const require = createRequire(import.meta.url);
const uri = createRequire(require.resolve('ajv'))('fast-uri');

// Exercise middleware with real streams, without opening a socket or loading
// the production entrypoint (which initializes remote services).
const boundary = 'agent5-boundary';
const field = (name, value) =>
  '--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"\r\n\r\n' + value + '\r\n';
const file = (name = 'file', value = 'synthetic') =>
  '--' + boundary + '\r\nContent-Disposition: form-data; name="' + name +
  '"; filename="fixture.pdf"\r\nContent-Type: application/pdf\r\n\r\n' + value + '\r\n';
const end = '--' + boundary + '--\r\n';

function parse(body, options = {}, { contentType, interrupt = false, single = true, beforeInterrupt } = {}) {
  const req = new PassThrough();
  req.headers = {
    'content-type': contentType ?? 'multipart/form-data; boundary=' + boundary,
    'content-length': String(Buffer.byteLength(body) + (interrupt ? 100 : 0)),
  };
  const upload = multer({ storage: multer.memoryStorage(), ...options });
  const middleware = single ? upload.single('file') : upload.any();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      req.destroy();
      reject(new Error('Multipart middleware did not complete'));
    }, 10000);
    middleware(req, {}, (error) => {
      clearTimeout(timer);
      resolve({ req, error });
    });
    if (interrupt) {
      req.write(body);
      setImmediate(async () => {
        try {
          await beforeInterrupt?.();
        } catch (error) {
          reject(error);
        } finally {
          req.destroy(new Error('synthetic disconnect'));
        }
      });
    } else {
      req.end(body);
    }
  });
}

test('multipart preserves fields, bytes and metadata for single and report uploads', async () => {
  const { req, error } = await parse(field('title', 'Fixture') + file() + end);
  assert.ifError(error);
  assert.equal(req.body.title, 'Fixture');
  assert.equal(req.file.originalname, 'fixture.pdf');
  assert.equal(req.file.mimetype, 'application/pdf');
  assert.equal(req.file.buffer.toString(), 'synthetic');
  const report = await parse(file('inline_doc_1') + file('inline_doc_2') + end, {}, { single: false });
  assert.ifError(report.error);
  assert.deepEqual(report.req.files.map((item) => item.fieldname), ['inline_doc_1', 'inline_doc_2']);
});

test('multipart rejects missing boundary, truncated payload and unexpected file', async () => {
  assert.match((await parse(file() + end, {}, { contentType: 'multipart/form-data' })).error.message, /boundary/i);
  assert.match((await parse(file())).error.message, /Unexpected end/i);
  assert.equal((await parse(file('other') + end)).error.code, 'LIMIT_UNEXPECTED_FILE');
});

test('multipart enforces file, count, field and part limits including async filter', async () => {
  assert.ifError((await parse(file('file', '1234') + end, { limits: { fileSize: 4 } })).error);
  for (const fileFilter of [undefined, (_req, _file, cb) => setTimeout(() => cb(null, true), 10)]) {
    const result = await parse(file('file', '12345') + end, { limits: { fileSize: 4 }, fileFilter });
    assert.equal(result.error.code, 'LIMIT_FILE_SIZE');
  }
  assert.equal((await parse(file() + file() + end, { limits: { files: 1 } })).error.code, 'LIMIT_FILE_COUNT');
  assert.equal((await parse(field('a', 'long') + end, { limits: { fieldSize: 2 } })).error.code, 'LIMIT_FIELD_VALUE');
  assert.equal((await parse(field('a', '1') + field('b', '2') + end, { limits: { parts: 1 } })).error.code, 'LIMIT_PART_COUNT');
  assert.equal((await parse(field('a[100]', '1') + end, { limits: { fieldArrayIndexLimit: 10 } })).error.code, 'LIMIT_FIELD_ARRAY_INDEX');
});

test('interrupted memory and disk uploads complete with error and clean partial files', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'agent5-upload-'));
  try {
    const disk = multer.diskStorage({ destination: dir, filename: (_req, _file, cb) => cb(null, 'partial.pdf') });
    for (const storage of [multer.memoryStorage(), disk]) {
      const result = await parse(file(), { storage }, {
        interrupt: true,
        beforeInterrupt: async () => {
          if (storage !== disk) return;
          // Wait for actual partial output, not a fixed disk-latency assumption.
          for (let attempt = 0; attempt < 200; attempt += 1) {
            const partial = await stat(join(dir, 'partial.pdf')).catch((error) => {
              if (error.code === 'ENOENT') return null;
              throw error;
            });
            if (partial?.size > 0) return;
            await delay(10);
          }
          assert.fail('Partial upload was not written before interruption');
        },
      });
      assert.ok(result.error);
      assert.deepEqual(result.error.storageErrors ?? [], []);
      assert.deepEqual(await readdir(dir), []);
    }
    assert.ifError((await parse(file() + end)).error);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('nodemailer renders feedback-style MIME in memory with no SMTP delivery', async () => {
  const transport = nodemailer.createTransport({
    streamTransport: true, buffer: true, newline: 'unix',
    disableFileAccess: true, disableUrlAccess: true,
  });
  const result = await transport.sendMail({
    from: 'app@example.invalid', to: 'support@example.invalid',
    replyTo: 'author@example.invalid', subject: 'Synthetic feedback',
    text: 'Synthetic body', html: '<p>Synthetic body</p>',
    attachments: [{ filename: 'fixture.txt', content: Buffer.from('synthetic attachment') }],
  });
  assert.deepEqual(result.envelope.to, ['support@example.invalid']);
  const message = result.message.toString();
  assert.match(message, /Subject: Synthetic feedback/);
  assert.match(message, /Reply-To: author@example.invalid/);
  assert.match(message, /multipart\/mixed/);
  assert.match(message, /fixture.txt/);
  assert.match(message, /Synthetic body/);
  await assert.rejects(transport.sendMail({
    from: 'app@example.invalid', to: 'support@example.invalid',
    attachments: [{ path: '/nonexistent-agent5-fixture' }],
  }), /File access rejected/i);
  transport.close();
});

test('qs remains compatible with Express extended query parsing and rejects prototype injection', () => {
  const app = express();
  app.set('query parser', 'extended');
  assert.deepEqual(app.get('query parser fn')('filter[name]=fixture&tags[]=a&tags[]=b'),
    { filter: { name: 'fixture' }, tags: ['a', 'b'] });
  assert.deepEqual(qs.parse('__proto__[polluted]=true'), {});
  assert.equal({}.polluted, undefined);
  assert.equal(qs.stringify({ tags: ['a', 'b'] }), 'tags%5B0%5D=a&tags%5B1%5D=b');
  assert.doesNotThrow(() => qs.stringify(qs.parse('x[constructor][isBuffer]=y', { plainObjects: true })));
});

test('fast-uri and AJV retain URI resolution and referenced schema validation', () => {
  assert.equal(uri.resolve('https://example.invalid/schemas/root.json', './child.json'), 'https://example.invalid/schemas/child.json');
  const ajv = new Ajv();
  ajv.addSchema({ $id: 'https://example.invalid/child.json', type: 'string' });
  const validate = ajv.compile({ $ref: 'https://example.invalid/child.json' });
  assert.equal(validate('fixture'), true);
  assert.equal(validate(42), false);
});

test('Hono handles local requests and body parsing without listening', async () => {
  const app = new Hono();
  app.post('/fixture', async (c) => c.json(await c.req.parseBody()));
  const response = await app.request('http://example.invalid/fixture', {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: 'title=fixture',
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { title: 'fixture' });
});

test('MCP client handshake and tool listing work over simulated in-memory transport', async () => {
  const client = new Client({ name: 'agent5-client', version: '1.0.0' });
  const server = new Server({ name: 'agent5-server', version: '1.0.0' }, { capabilities: { tools: {} } });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [{ name: 'fixture', inputSchema: { type: 'object', properties: {} } }],
  }));
  const [a, b] = InMemoryTransport.createLinkedPair();
  try {
    await server.connect(b);
    await client.connect(a);
    assert.equal((await client.listTools()).tools[0].name, 'fixture');
  } finally {
    await client.close();
    await server.close();
  }
});
