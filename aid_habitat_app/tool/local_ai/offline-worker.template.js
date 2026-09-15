const BUILD = __BUILD__;
const ASSETS = __ASSETS__;
const CACHE = `appergo-ai-shell-${BUILD}`;
const paths = new Set(ASSETS.map(asset => new URL(asset.path, self.registration.scope).href));
self.addEventListener('install', event => event.waitUntil((async () => {
  const cache = await caches.open(CACHE);
  try {
    for (const asset of ASSETS) {
      const url = new URL(asset.path, self.registration.scope).href;
      const response = await fetch(url, {cache: 'no-store', credentials: 'omit'});
      if (!response.ok) throw new Error('Missing static asset');
      const bytes = await response.clone().arrayBuffer();
      const digest = await crypto.subtle.digest('SHA-256', bytes);
      const hex = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
      if (hex !== asset.sha256) throw new Error('Build changed during installation');
      await cache.put(url, response);
    }
    await self.skipWaiting();
  } catch (error) { await caches.delete(CACHE); throw error; }
})()));
self.addEventListener('activate', event => event.waitUntil((async () => {
  for (const key of await caches.keys()) {
    if (key.startsWith('appergo-ai-shell-') && key !== CACHE) await caches.delete(key);
  }
  await self.clients.claim();
})()));
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin || url.search) return;
  // Only exact static build assets and the root navigation. Never API calls,
  // uploads, arbitrary SPA routes, authentication or patient documents.
  const root = new URL('./', self.registration.scope).href;
  const target = request.mode === 'navigate' && url.href === root
    ? new URL('index.html', root).href : url.href;
  if (!paths.has(target)) return;
  event.respondWith((async () => {
    try { return await fetch(request); }
    catch { return (await (await caches.open(CACHE)).match(target)) || Response.error(); }
  })());
});
