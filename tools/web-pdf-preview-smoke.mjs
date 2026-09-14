import assert from 'node:assert/strict';
import http from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { PDFDocument, PDFName } from 'pdf-lib';

// Usage: PLAYWRIGHT_MODULE=/absolute/path/to/playwright/index.mjs node
// tools/web-pdf-preview-smoke.mjs /absolute/path/to/smoke-build
const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(process.argv[2]);
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    const file = path.resolve(root, `.${decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname)}`);
    if (!file.startsWith(root + path.sep)) throw new Error('path');
    const bytes = await readFile(file);
    response.setHeader('Content-Type', { '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm', '.json': 'application/json' }[path.extname(file)] || 'application/octet-stream');
    response.end(bytes);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : { channel: 'chrome' }), headless: true });
let page;
try {
  const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  page = await context.newPage();
  const errors = [];
  page.on('pageerror', error => { errors.push(error.stack || error.message); console.log('Browser error:', error.stack || error.message); });
  page.on('console', message => { if (message.type() === 'error') console.log('Console:', message.text()); });
  await page.goto(`http://127.0.0.1:${server.address().port}`);
  await page.waitForFunction(() => document.querySelector('#smoke-result')?.textContent, undefined, { timeout: 60000 });
  const state = () => page.locator('#smoke-result').textContent().then(JSON.parse);
  assert.equal((await state()).ready, true, JSON.stringify(await state()));
  await page.locator('flt-semantics-placeholder').evaluate(element => element.click());
  const save = page.getByRole('button', { name: 'Enregistrer', exact: true });
  await save.waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Crayon', exact: true }).waitFor();
  await page.screenshot({ path: path.join(root, 'preview-desktop.png') });
  await page.getByRole('button', { name: 'Pivoter le document de 90°' }).click();
  await page.evaluate(() => document.dispatchEvent(new Event('smoke-fail')));
  await page.waitForFunction(() => document.querySelector('#smoke-result').dataset.failureReady === 'true');
  await save.click();
  await page.getByText(/synthetic failure/).last().waitFor({ timeout: 30000 });
  assert.equal((await state()).saves, 0);
  assert.ok((await state()).annotations);
  await page.evaluate(() => document.dispatchEvent(new Event('smoke-retry')));
  await page.waitForFunction(() => document.querySelector('#smoke-result').dataset.retryReady === 'true');
  await context.setOffline(true);
  await save.click();
  await page.waitForFunction(() => JSON.parse(document.querySelector('#smoke-result').textContent).saves === 1);
  let current = await state();
  assert.equal(current.annotations, null);
  assert.equal(current.operations, 1);
  const bytes = Buffer.from(current.dataUrl.split(',')[1], 'base64');
  const pdf = await PDFDocument.load(bytes);
  assert.equal(pdf.getPageCount(), 2);
  assert.equal(pdf.getPage(0).getRotation().angle, 90);
  assert.ok(pdf.getPage(1).node.Resources().has(PDFName.of('XObject')));
  await writeFile(path.join(root, 'browser-saved.pdf'), bytes);
  const draw = async (x, y) => {
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 60, y + 45, { steps: 6 });
    await page.mouse.up();
  };
  await draw(520, 420);
  await save.click();
  await page.waitForFunction(() => JSON.parse(document.querySelector('#smoke-result').textContent).saves === 2);
  current = await state();
  const drawn = Buffer.from(current.dataUrl.split(',')[1], 'base64');
  const drawnPdf = await PDFDocument.load(drawn);
  assert.ok(drawnPdf.getPage(0).node.Resources().has(PDFName.of('XObject')));
  assert.equal(drawnPdf.getPage(0).getRotation().angle, 90);
  await writeFile(path.join(root, 'browser-drawn.pdf'), drawn);
  await page.getByRole('button', { name: 'Annuler', exact: true }).click();
  await draw(600, 460);
  await save.click();
  await page.waitForFunction(() => JSON.parse(document.querySelector('#smoke-result').textContent).saves === 3);
  current = await state();
  assert.notEqual(current.dataUrl, `data:application/pdf;base64,${drawn.toString('base64')}`);
  assert.equal(current.operations, 1);
  await draw(700, 430);
  const next = await page.getByRole('button', { name: 'Page suivante', exact: true }).boundingBox();
  await page.mouse.dblclick(next.x + next.width / 2, next.y + next.height / 2);
  await page.getByRole('group', { name: /2 \/ 2/ }).waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Crayon', exact: true }).waitFor();
  await draw(550, 420);
  await save.click();
  await page.waitForFunction(() => JSON.parse(document.querySelector('#smoke-result').textContent).saves === 4);
  current = await state();
  const multi = Buffer.from(current.dataUrl.split(',')[1], 'base64');
  assert.equal((await PDFDocument.load(multi)).getPageCount(), 2);
  assert.equal(current.operations, 1);
  await writeFile(path.join(root, 'browser-multipage.pdf'), multi);
  await page.getByRole('button', { name: 'Télécharger', exact: true }).click();
  await page.waitForFunction(() => JSON.parse(document.querySelector('#smoke-result').textContent).downloads === 1);
  await page.setViewportSize({ width: 820, height: 1180 });
  await page.mouse.move(5, 5);
  await page.waitForTimeout(700);
  await page.screenshot({ path: path.join(root, 'preview-tablet.png') });
  assert.deepEqual(errors, [], 'no uncaught browser errors');
  console.log('PASS: real Flutter web viewer, PDF worker, SQLite rollback/retry, offline save, unvisited legacy page, drawing, undo, repeated save, rapid page navigation and download callback; no uncaught errors.');
} catch (error) {
  console.log(await page?.locator('body').innerText());
  console.log(await page?.locator('body').ariaSnapshot());
  await page?.screenshot({ path: path.join(root, 'preview-failure.png') });
  throw error;
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
