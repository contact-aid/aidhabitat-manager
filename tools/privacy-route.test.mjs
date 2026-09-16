import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';

const configPath = path.resolve('aid_habitat_app/nginx.conf');

test('privacy route cannot fall back to the authenticated SPA', async () => {
  const config = await readFile(configPath, 'utf8');
  const route = config.match(/location = \/confidentialite \{([^}]+)\}/)?.[1];
  assert.ok(route);
  assert.match(route, /try_files \/confidentialite\.html =404;/);
  assert.match(route, /default_type text\/html;/);
  assert.match(route, /X-Robots-Tag "noindex" always;/);
  assert.match(route, /Cache-Control "no-store" always;/);
  assert.doesNotMatch(route, /auth_basic|proxy_pass|\/index\.html/);
});

test('privacy route serves standalone HTML and rejects an unpublished policy', {
  skip: process.env.TEST_PRIVACY_DOCKER !== '1',
}, async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'appergo-privacy-'));
  let container;
  const docker = (...args) => execFileSync('docker', args, { encoding: 'utf8', timeout: 120000 }).trim();
  try {
    await writeFile(path.join(directory, 'index.html'), 'SPA_SENTINEL');
    container = docker('run', '--rm', '-d', '-p', '127.0.0.1::80',
      '-v', `${directory}:/usr/share/nginx/html:ro`,
      '-v', `${configPath}:/etc/nginx/conf.d/default.conf:ro`, 'nginx:alpine');
    docker('exec', container, 'nginx', '-t');
    const port = docker('port', container, '80/tcp').split(':').at(-1);
    const base = `http://127.0.0.1:${port}`;
    let missing;
    for (let attempt = 0; attempt < 40; attempt++) {
      try { missing = await fetch(`${base}/confidentialite`); break; }
      catch (error) {
        if (attempt === 39) throw error;
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
    assert.equal(missing.status, 404);
    assert.doesNotMatch(await missing.text(), /SPA_SENTINEL/);
    const html = '<!doctype html><html lang="fr"><title>Test</title><p>POLICY_TEST_ONLY</p></html>';
    await writeFile(path.join(directory, 'confidentialite.html'), html);
    const response = await fetch(`${base}/confidentialite`);
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /text\/html/);
    assert.equal(response.headers.get('x-robots-tag'), 'noindex');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal(response.headers.get('www-authenticate'), null);
    assert.equal(await response.text(), html);
    for (const suffix of ['/confidentialite/', '/confidentialite.html']) {
      const redirect = await fetch(base + suffix, { redirect: 'manual' });
      assert.equal(redirect.status, 308);
      assert.equal(new URL(redirect.headers.get('location'), base).pathname, '/confidentialite');
    }
    assert.equal(await (await fetch(`${base}/`)).text(), 'SPA_SENTINEL');
  } finally {
    if (container) docker('stop', container);
    await rm(directory, { recursive: true, force: true });
  }
});
