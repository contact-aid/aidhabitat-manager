import assert from 'node:assert/strict';
import http from 'node:http';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { chromium } from 'playwright';
import { PNG } from 'pngjs';

// Synthetic standalone Flutter fixture only. Never opens an authenticated app.
const root = path.resolve(process.argv[2]);
const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const file = path.resolve(root, `.${url.pathname === '/' ? '/index.html' : url.pathname}`);
    if (!file.startsWith(`${root}${path.sep}`)) throw Error('path');
    res.setHeader('Content-Type', { '.html': 'text/html', '.js': 'text/javascript',
      '.wasm': 'application/wasm', '.json': 'application/json' }[path.extname(file)] || 'application/octet-stream');
    res.end(await readFile(file));
  } catch { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const browser = await chromium.launch({ ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : { channel: 'chrome' }), headless: true });
try {
  for (const viewport of [{ width: 1280, height: 900 }, { width: 820, height: 1180 }]) {
    const context = await browser.newContext({ viewport });
    const errors = [];
    const page = await context.newPage();
    page.on('pageerror', e => errors.push(e.message));
    await page.goto(`http://127.0.0.1:${server.address().port}/?image=1`);
    await page.waitForFunction(() => document.querySelector('#smoke-result')?.textContent);
    const state = () => page.locator('#smoke-result').textContent().then(JSON.parse);
    assert.equal((await state()).ready, true, JSON.stringify(await state()));
    await page.locator('flt-semantics-placeholder').evaluate(el => el.click());
    const rotate = page.getByRole('button', { name: 'Pivoter le document de 90°' });
    const save = page.getByRole('button', { name: 'Enregistrer', exact: true });
    await rotate.waitFor();
    const toolbar = await rotate.boundingBox();
    await context.setOffline(true);
    for (let turn = 1; turn <= 8; turn++) {
      if (turn === 1) {
        await page.getByRole('button', { name: 'Crayon', exact: true }).click();
        await page.mouse.move(viewport.width / 2 - 20, viewport.height / 2 - 20);
        await page.mouse.down();
        await page.mouse.move(viewport.width / 2 + 20, viewport.height / 2 + 20, { steps: 8 });
        await page.mouse.up();
      }
      await rotate.click();
      const position = await rotate.boundingBox();
      assert.ok(Math.abs(position.y - toolbar.y) < 1, 'toolbar does not rotate');
      await save.click();
      await page.waitForFunction(n => JSON.parse(document.querySelector('#smoke-result').textContent).saves === n, turn);
      const current = await state();
      assert.deepEqual(current.dimensions, turn % 2 ? [320, 480] : [480, 320]);
      const image = PNG.sync.read(Buffer.from(current.dataUrl.split(',')[1], 'base64'));
      const pixel = (Math.floor(image.height * 0.6) * image.width + Math.floor(image.width * 0.6)) * 4;
      assert.deepEqual([...image.data.subarray(pixel, pixel + 3)], [240, 210, 10]);
      assert.equal(current.operations, 1);
      await page.evaluate(() => document.dispatchEvent(new Event('smoke-reopen')));
      await page.waitForFunction(n => Number(document.querySelector('#smoke-result').dataset.generation) === n, turn + 1);
      await page.waitForTimeout(200);
      await rotate.waitFor();
    }
    const bounds = async () => {
      const shot = PNG.sync.read(await page.screenshot());
      let x0 = shot.width, x1 = 0, y0 = shot.height, y1 = 0;
      for (let y = 0; y < shot.height; y++) for (let x = 0; x < shot.width; x++) {
        const i = (y * shot.width + x) * 4;
        if (shot.data[i] === 240 && shot.data[i + 1] === 210 && shot.data[i + 2] === 10) {
          x0 = Math.min(x0, x); x1 = Math.max(x1, x);
          y0 = Math.min(y0, y); y1 = Math.max(y1, y);
        }
      }
      assert.ok(x1 > x0 && y1 > y0, 'nonblank image');
      return [x1 - x0, y1 - y0];
    };
    const initial = await bounds();
    await page.getByRole('button', { name: /Agrandir/ }).click();
    await page.waitForTimeout(250);
    const zoomed = await bounds();
    // The viewport may clip the enlarged image. Exact transform increments
    // are asserted in document_viewport_test.dart, not inferred from clipping.
    assert.ok(zoomed[0] >= initial[0] - 2 && zoomed[1] >= initial[1] - 2);
    await page.getByRole('button', { name: /Réduire/ }).click();
    await page.waitForTimeout(250);
    const restored = await bounds();
    assert.ok(Math.abs(restored[0] - initial[0]) < 3 && Math.abs(restored[1] - initial[1]) < 3);
    await page.getByRole('button', { name: 'Déplacer l’image' }).click();
    await page.mouse.move(viewport.width / 2, viewport.height / 2);
    await page.mouse.down();
    await page.mouse.move(viewport.width / 2 + 35, viewport.height / 2 + 25, { steps: 5 });
    await page.mouse.up();
    assert.equal((await state()).saves, 8, 'zoom is not an edit');
    await page.screenshot({ path: path.join(root, `rotation-image-${viewport.width}.png`) });
    await writeFile(path.join(root, `rotation-image-${viewport.width}-saved.png`),
      Buffer.from((await state()).dataUrl.split(',')[1], 'base64'));
    assert.deepEqual(errors, []);
    await context.close();
  }
  console.log('PASS: image dimensions/pixels stable after 8 rotations and reopen, offline, stationary toolbar, zoom 10%, desktop/tablet.');
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
}
