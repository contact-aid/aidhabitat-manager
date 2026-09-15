(() => {
  let worker;
  let nextId = 0;
  let progress = 0;
  let idle;
  let generation = 0;
  const pending = new Map();
  const stop = () => {
    generation++;
    clearTimeout(idle);
    worker?.terminate();
    worker = null;
    for (const request of pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error('Reformulation interrompue. Texte original conserve.'));
    }
    pending.clear();
  };
  function request(method, payload = {}) {
    clearTimeout(idle);
    if (!worker) {
      worker = new Worker(new URL('local-ai/worker.js', document.baseURI));
      worker.onmessage = ({data}) => {
        if (data.progress !== undefined) { progress = data.progress; return; }
        const item = pending.get(data.id);
        if (!item) return;
        pending.delete(data.id);
        clearTimeout(item.timer);
        if (data.error) {
          const error = new Error(data.error);
          error.code = data.code;
          item.reject(error);
        }
        else item.resolve(data.result);
        if (!pending.size) idle = setTimeout(stop, 120000);
      };
      worker.onerror = stop;
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(stop, method === 'prepare' ? 1800000 : 130000);
      pending.set(id, {resolve, reject, timer});
      worker.postMessage({id, method, ...payload});
    });
  }
  window.aidHabitatLocalAiStatus = async () => {
    if (!window.isSecureContext || !navigator.gpu || !navigator.serviceWorker) {
      return JSON.stringify({supported: false, installed: false});
    }
    const result = await request('status');
    const registration = await navigator.serviceWorker.getRegistration();
    result.installed = result.installed && localStorage.getItem('appergo-local-ai-qwen3-v1') === 'complete';
    result.offlineReady = !!registration?.active?.scriptURL.endsWith('/ai_offline_worker.js');
    return JSON.stringify(result);
  };
  window.aidHabitatLocalAiProgress = () => progress;
  window.aidHabitatLocalAiCancel = stop;
  window.aidHabitatLocalAiPrepare = async () => {
    const attempt = generation;
    const checkCancelled = () => {
      if (attempt !== generation) throw new Error('Preparation annulee.');
    };
    progress = 0;
    await navigator.storage?.persist?.();
    const estimate = await navigator.storage?.estimate?.();
    if (estimate?.quota && estimate.quota - (estimate.usage ?? 0) < 1300000000) {
      throw new Error('Espace local insuffisant pour le modele (au moins 1,3 Go requis).');
    }
    const result = await request('prepare');
    clearTimeout(idle);
    checkCancelled();
    // Explicit opt-in; this worker caches only a build-time list of static files.
    const registration = await navigator.serviceWorker.register('ai_offline_worker.js', {updateViaCache: 'none'});
    await registration.update();
    const installing = registration.installing || registration.waiting;
    if (installing && installing.state !== 'activated') {
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Preparation hors ligne incomplete.')), 180000);
        const checkState = () => {
          if (installing.state === 'activated') { clearTimeout(timeout); resolve(); }
          if (installing.state === 'redundant') { clearTimeout(timeout); reject(new Error('Preparation hors ligne impossible.')); }
        };
        installing.addEventListener('statechange', checkState);
        checkState();
      });
    }
    checkCancelled();
    localStorage.setItem('appergo-local-ai-qwen3-v1', 'complete');
    idle = setTimeout(stop, 120000);
    return JSON.stringify(result);
  };
  window.aidHabitatLocalAiRewrite = async (text, mode) => {
    try { return await request('rewrite', {text, mode}); }
    catch (error) {
      if (error.code === 'model_unavailable') localStorage.removeItem('appergo-local-ai-qwen3-v1');
      throw error;
    }
  };
  window.addEventListener('pagehide', stop);
})();
