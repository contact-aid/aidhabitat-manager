import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const deferred = () => {
  let resolve;
  const promise = new Promise((done) => { resolve = done; });
  return { promise, resolve };
};
const tick = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };
const items = (count) => Array.from({ length: count }, (_, i) => ({ id: `rec-${i}`, wikiItemId: `wiki-${i}`, note: `Description ${i}` }));
const serviceSource = readFileSync(new URL('../services/dataService.ts', import.meta.url), 'utf8');
const start = serviceSource.indexOf('export const fetchVisitRecommendations =');
const end = serviceSource.indexOf('\n// Helper to map a raw beneficiary', start);
const compiled = ts.transpile(serviceSource.slice(start, end).replaceAll('export ', '') + '\nglobalThis.api = { fetchVisitRecommendations, saveVisitRecommendations, flushQueuedVisitRecommendations };', { target: ts.ScriptTarget.ES2022 });

function service({ initial = {}, request = async () => ({ success: true, data: { items: [] } }), online = true } = {}) {
  let cache = initial;
  let queue = {};
  let durableCache = JSON.stringify(cache);
  let durableQueue = '{}';
  const context = vm.createContext({
    readVisitRecommendationsCacheMap: () => cache,
    writeVisitRecommendationsCacheMap: (next) => { cache = next; durableCache = JSON.stringify(next); },
    readVisitRecommendationsQueueMap: () => queue,
    writeVisitRecommendationsQueueMap: (next) => { queue = next; durableQueue = JSON.stringify(next); },
    apiFetch: request,
    shouldAttemptBackgroundSync: () => online,
    ensureBackgroundSyncLoop: () => {},
    recommendationsFlushPromise: null,
    recommendationsOnlineListenerRegistered: false,
    recommendationsFlushTimer: null,
    PATCH_SYNC_TRIGGER_DELAY_MS: 700,
    window: { addEventListener() {}, setTimeout() { return 1; }, clearTimeout() {} },
    navigator: { onLine: online },
  });
  vm.runInContext(compiled, context);
  return { ...context.api, cache: () => cache, queue: () => queue, disk: () => ({ cache: JSON.parse(durableCache), queue: JSON.parse(durableQueue) }) };
}

test('three selected recommendations survive leaving immediately, offline and reopening', async () => {
  const store = service({ online: false });
  const save = store.saveVisitRecommendations('dossier-a', items(3));
  assert.equal(store.disk().cache['dossier-a'].items.length, 3, 'durable before awaiting save');
  assert.equal(store.disk().queue['dossier-a'].items.length, 3);
  await save;
  const reopened = service({ initial: store.disk().cache, online: false });
  assert.deepEqual(await reopened.fetchVisitRecommendations('dossier-a'), items(3));
});

for (const success of [true, false]) {
  test(`older ${success ? 'successful' : 'failed'} PUT preserves edits made during synchronization`, async () => {
    const gate = deferred();
    let calls = 0;
    const store = service({ request: async () => ++calls === 1 ? gate.promise : { success: true, data: { items: items(3) } } });
    await store.saveVisitRecommendations('a', items(1));
    const flush = store.flushQueuedVisitRecommendations();
    await store.saveVisitRecommendations('a', items(3));
    gate.resolve({ success, error: success ? null : 'offline', data: { items: items(1) } });
    await flush;
    assert.equal(store.cache().a.items.length, 3);
    assert.equal(store.queue().a.items.length, 3);
    await store.flushQueuedVisitRecommendations();
    assert.equal(store.cache().a.items.length, 3);
    assert.equal(store.queue().a, undefined);
  });
}

for (const cached of [true, false]) {
  test(`delayed GET cannot overwrite a newer local save (${cached ? 'warm' : 'cold'} cache)`, async () => {
    const gate = deferred();
    const store = service({ initial: cached ? { a: { items: items(1) } } : {}, request: () => gate.promise });
    const read = store.fetchVisitRecommendations('a');
    await tick();
    await store.saveVisitRecommendations('a', items(3));
    gate.resolve({ success: true, data: { items: [] } });
    await read;
    await tick();
    assert.equal(store.cache().a.items.length, 3);
    assert.equal(store.queue().a.items.length, 3);
  });
}

test('a failed initial GET is an error rather than an empty editable list', async () => {
  const store = service({ request: async () => ({ success: false, error: 'Unavailable' }) });
  await assert.rejects(store.fetchVisitRecommendations('a'), /Unavailable/);
  assert.equal(store.cache().a, undefined);
});

// Execute the production hook with a deterministic hook lifecycle, including
// effect cleanup on dossier changes/unmount. No timers or network are required.
const hookSource = readFileSync(new URL('../components/hooks/useVisitRecommendations.ts', import.meta.url), 'utf8');
const hookCompiled = ts.transpile(hookSource.replace(/^import .*;\n/gm, '').replace('export function', 'function') + '\nglobalThis.hook = useVisitRecommendations;', { target: ts.ScriptTarget.ES2022 });
function mountHook(store) {
  let slots = [];
  let index = 0;
  let effects = [];
  const context = vm.createContext({
    console,
    ...store,
    useRef(initial) { const i = index++; return slots[i] ??= { current: initial }; },
    useState(initial) {
      const i = index++;
      if (!(i in slots)) slots[i] = initial;
      return [slots[i], (value) => { slots[i] = value; }];
    },
    useEffect(effect, deps) {
      const i = index++;
      if (!slots[i] || deps.some((dep, n) => dep !== slots[i].deps[n])) {
        slots[i]?.cleanup?.();
        slots[i] = { deps };
        effects.push(() => { slots[i].cleanup = effect(); });
      }
    },
  });
  vm.runInContext(hookCompiled, context);
  return {
    render(id) { index = 0; const result = context.hook(id); const pending = effects; effects = []; pending.forEach((run) => run()); return result; },
    unmount() { slots.forEach((slot) => slot?.cleanup?.()); },
  };
}

test('production hook persists consecutive selections and text edits before navigation', async () => {
  const store = service({ initial: { a: { items: [] } }, online: false });
  let hook = mountHook(store);
  hook.render('a');
  await tick();
  const view = hook.render('a');
  assert.equal(view.ready, true);
  for (const item of items(3)) view.update((previous) => [...previous, item]);
  view.update((previous) => previous.map((item, i) => i === 0 ? { ...item, note: 'Texte personnalisé' } : item));
  hook.unmount();
  assert.equal(store.disk().cache.a.items.length, 3);
  assert.equal(store.disk().cache.a.items[0].note, 'Texte personnalisé');
  hook = mountHook(store);
  hook.render('a');
  await tick();
  const reopened = hook.render('a');
  assert.equal(reopened.items.length, 3);
  reopened.update((previous) => previous.filter((item) => item.id !== 'rec-1'));
  hook.unmount();
  assert.equal(store.disk().cache.a.items.length, 2, 'explicit deletion is saved too');
});

test('late dossier load and stale callbacks cannot populate or save another dossier', async () => {
  const old = deferred();
  const writes = [];
  const hook = mountHook({
    fetchVisitRecommendations: (id) => id === 'a' ? old.promise : Promise.resolve(items(2)),
    saveVisitRecommendations: async (...args) => { writes.push(args); },
  });
  const stale = hook.render('a');
  stale.update(() => items(3));
  hook.render('b');
  await tick();
  old.resolve(items(3));
  await tick();
  stale.update(() => items(3));
  const current = hook.render('b');
  assert.equal(current.items.length, 2);
  assert.equal(writes.length, 0, 'loading/hydration is read-only');
  current.update((previous) => [...previous, { id: 'new' }]);
  assert.equal(writes[0][0], 'b');
  hook.unmount();
});

test('failed loading keeps the production hook read-only and never saves an empty list', async () => {
  let writes = 0;
  const hook = mountHook({
    fetchVisitRecommendations: async () => { throw new Error('offline'); },
    saveVisitRecommendations: async () => { writes++; },
  });
  hook.render('a');
  await tick();
  const view = hook.render('a');
  assert.equal(view.ready, false);
  assert.match(view.error, /Chargement/);
  view.update(() => []);
  hook.unmount();
  assert.equal(writes, 0);
});
