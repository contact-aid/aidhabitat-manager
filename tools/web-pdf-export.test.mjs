import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import * as lib from 'pdf-lib';
import upngModule from '@pdf-lib/upng';
import '../aid_habitat_app/web/pdf-export/pdf-export-core.js';

const { exportPdf } = globalThis.AidHabitatPdfExport;
const UPNG = upngModule.default;
const require = createRequire(import.meta.url);
const root = await mkdtemp(path.join(tmpdir(), 'aidhabitat-web-pdf-'));
console.log(`Synthetic PDF fixtures: ${root}`);

export function inkPng(width, height, legacy = false) {
  const bytes = new Uint8Array(width * height * 4);
  const pageWidth = legacy ? height * 0.75 : width;
  const left = (width - pageWidth) / 2;
  const cx = Math.round(left + pageWidth * 0.2), cy = Math.round(height * 0.3);
  for (let y = cy - 4; y <= cy + 4; y++) {
    for (let x = cx - 4; x <= cx + 4; x++) {
      bytes.set([240, 10, 10, 255], (y * width + x) * 4);
    }
  }
  return new Uint8Array(UPNG.encode([bytes.buffer], width, height, 0));
}

async function fixture() {
  const doc = await lib.PDFDocument.create();
  for (let i = 0; i < 5; i++) {
    const page = doc.addPage([300, 400]);
    page.drawText(`ORIGINAL PAGE ${i + 1}`, { x: 40, y: 220, size: 16 });
    page.setRotation(lib.degrees(i < 4 ? i * 90 : 0));
    if (i === 2) {
      page.setMediaBox(-20, -30, 350, 450);
      page.setCropBox(0, 0, 300, 400);
    }
    const annotation = doc.context.register(doc.context.obj({
      Type: 'Annot', Subtype: 'Square', Rect: [210, 60, 240, 90], C: [0, 0, 1],
      F: 4, Border: [0, 0, 2],
    }));
    page.node.set(lib.PDFName.of('Annots'), doc.context.obj([annotation]));
  }
  return doc.save();
}

test('real PDF: 4 rotations, crop offset, text, untouched page and foreign annotations', async () => {
  const source = await fixture();
  const original = source.slice();
  const pages = {};
  for (let i = 0; i < 4; i++) pages[i + 1] = {
    bytes: inkPng(i % 2 ? 400 : 300, i % 2 ? 300 : 400), legacyViewport: false,
  };
  const output = await exportPdf({ source, pages, quarterTurns: 1 }, lib);
  assert.deepEqual(source, original);
  const reopened = await lib.PDFDocument.load(output);
  assert.equal(reopened.getPageCount(), 5);
  reopened.getPages().forEach((page, i) => {
    assert.equal(page.getRotation().angle, i < 4 ? ((i + 1) % 4) * 90 : 90);
    assert.equal(page.node.Annots().size(), 1);
  });
  const file = path.join(root, 'annotated.pdf');
  await writeFile(file, output);
  const text = execFileSync('pdftotext', [file, '-'], { encoding: 'utf8' });
  for (let i = 1; i <= 5; i++) assert.match(text, new RegExp(`ORIGINAL PAGE ${i}`));
  for (let i = 1; i <= 4; i++) {
    const prefix = path.join(root, `page-${i}`);
    execFileSync('pdftoppm', ['-cropbox', '-f', String(i), '-singlefile', '-scale-to', '800', '-png', file, prefix]);
    const buffer = await readFile(`${prefix}.png`);
    const png = UPNG.decode(buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength));
    const pixels = new Uint8Array(UPNG.toRGBA8(png)[0]);
    const x = Math.round(png.width * 0.7), y = Math.round(png.height * 0.2);
    let red = false;
    for (let dy = -8; dy <= 8; dy++) for (let dx = -8; dx <= 8; dx++) {
      const n = ((y + dy) * png.width + x + dx) * 4;
      if (pixels[n] > 180 && pixels[n + 1] < 60 && pixels[n + 2] < 60) red = true;
    }
    assert.ok(red, `red ink at expected rotated location, page ${i}`);
  }
});

test('legacy viewport margins are removed without stretching the page', async () => {
  const source = await fixture();
  const bytes = await exportPdf({ source, pages: {
    1: { bytes: inkPng(600, 400, true), legacyViewport: true },
  } }, lib);
  const pdf = await lib.PDFDocument.load(bytes);
  const image = { width: 600, height: 400 };
  assert.deepEqual(globalThis.AidHabitatPdfExport.placement(pdf.getPage(0).getCropBox(), 0, image, true),
    { x: -150, y: 0, width: 600, height: 400 });
  await writeFile(path.join(root, 'legacy.pdf'), bytes);
});

test('successive exports from opening source do not accumulate pages, layers or rotation', async () => {
  const source = await fixture();
  const pages = { 1: { bytes: inkPng(300, 400), legacyViewport: false } };
  const once = await exportPdf({ source, pages, quarterTurns: 1 }, lib);
  const twice = await exportPdf({ source, pages, quarterTurns: 1 }, lib);
  assert.equal(twice.length, once.length);
  const fullTurn = await lib.PDFDocument.load(await exportPdf({ source, pages, quarterTurns: 4 }, lib));
  assert.equal(fullTurn.getPage(0).getRotation().angle, 0);
});

for (const [name, pages] of [
  ['missing page', { 6: { bytes: inkPng(300, 400), legacyViewport: false } }],
  ['invalid PNG', { 1: { bytes: new Uint8Array([1, 2, 3]), legacyViewport: false } }],
  ['wrong dimensions', { 1: { bytes: inkPng(300, 300), legacyViewport: false } }],
  ['invalid page key', { '01': { bytes: inkPng(300, 400), legacyViewport: false } }],
]) test(`rejects ${name} without changing the original`, async () => {
  const source = await fixture();
  const original = source.slice();
  await assert.rejects(exportPdf({ source, pages }, lib));
  assert.deepEqual(source, original);
});

test('signed PDF is rejected without altering its signature', async () => {
  const pdf = await lib.PDFDocument.load(await fixture());
  pdf.context.register(pdf.context.obj({ Type: 'Sig', ByteRange: [0, 10, 20, 30] }));
  const source = await pdf.save();
  await assert.rejects(exportPdf({ source }, lib), /signe/);
});

test('broken PDF fails explicitly', async () => {
  await assert.rejects(exportPdf({ source: new Uint8Array([1, 2, 3]) }, lib));
});

test('fillable fields remain interactive with their stored values', async () => {
  const document = await lib.PDFDocument.load(await fixture());
  const field = document.getForm().createTextField('fixture-field');
  field.setText('ORIGINAL VALUE');
  field.addToPage(document.getPage(0), { x: 30, y: 30, width: 150, height: 25 });
  const source = await document.save();
  const result = await lib.PDFDocument.load(await exportPdf({ source,
    pages: { 1: { bytes: inkPng(300, 400), legacyViewport: false } } }, lib));
  assert.equal(result.getForm().getTextField('fixture-field').getText(), 'ORIGINAL VALUE');
  assert.equal(result.getPage(0).node.Annots().size(), 2);
});

test('vendored engine matches the existing pinned dependency', async () => {
  const vendored = await readFile(new URL('../aid_habitat_app/web/pdf-export/pdf-lib.min.js', import.meta.url));
  const installed = await readFile(require.resolve('pdf-lib/dist/pdf-lib.min.js'));
  assert.deepEqual(vendored, installed);
});
