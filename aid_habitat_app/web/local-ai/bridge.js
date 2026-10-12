(() => {
  let worker;
  let nextId = 0;
  let progress = 0;
  let idle;
  let generation = 0;
  const pending = new Map();
  let preparing = false;
  let phase = '';
  let lastError = '';
  const messages = {
    storage: 'Le navigateur ne répond pas à la vérification du stockage. Fermez cette fenêtre et réessayez.',
    space: 'Espace insuffisant : prévoyez au moins 1,3 Go libres.',
    unsupported: 'L’IA locale nécessite WebGPU. Vérifiez que l’accélération graphique est activée dans Chrome.',
    download: 'Le téléchargement ne répond pas. Vérifiez la connexion puis réessayez. Les notes sont conservées.',
    offline: 'Le modèle est prêt, mais la préparation hors ligne a échoué. Réessayez sans effacer les données du navigateur.',
  };
  function deadline(promise, ms, code) {
    let timer;
    return Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => { const error = new Error(messages[code]); error.setupCode = code; reject(error); }, ms);
    })]).catch(error => {
      const failure = error instanceof Error ? error : new Error(messages[code]);
      if (!failure.setupCode) failure.setupCode = code;
      throw failure;
    }).finally(() => clearTimeout(timer));
  }
  window.aidHabitatLocalAiPhase = () => phase;
  window.aidHabitatLocalAiLastError = () => lastError;
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
        if (!pending.size && !preparing) idle = setTimeout(stop, 120000);
      };
      worker.onerror = stop;
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(stop, method === 'prepare' ? 1800000 : method === 'status' ? 15000 : 130000);
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
    if (preparing) throw new Error('Préparation déjà en cours.');
    preparing = true;
    lastError = '';
    progress = 0;
    phase = 'Vérification du navigateur…';
    try {
    const state = await deadline(request('status'), 15000, 'unsupported');
    checkCancelled();
    if (!state.supported) { const error = new Error(messages.unsupported); error.setupCode = 'unsupported'; throw error; }
    phase = 'Vérification du stockage…';
    // Persistent storage is advisory, and must never strand the download UI.
    await deadline(Promise.resolve(navigator.storage?.persist?.()), 10000, 'storage').catch(() => {});
    checkCancelled();
    const estimate = await deadline(Promise.resolve(navigator.storage?.estimate?.()), 10000, 'storage');
    if (estimate?.quota && estimate.quota - (estimate.usage ?? 0) < 1300000000) {
      const error = new Error(messages.space); error.setupCode = 'space'; throw error;
    }
    checkCancelled();
    phase = 'Téléchargement et chargement du modèle…';
    const result = await deadline(request('prepare'), 1800000, 'download');
    clearTimeout(idle);
    checkCancelled();
    // Explicit opt-in; this worker caches only a build-time list of static files.
    phase = 'Préparation de l’accès hors ligne…';
    const registration = await deadline(navigator.serviceWorker.register('ai_offline_worker.js', {updateViaCache: 'none'}), 30000, 'offline');
    await deadline(registration.update(), 30000, 'offline');
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
    phase = 'Installation terminée';
    return JSON.stringify(result);
    } catch (error) {
      lastError = messages[error.setupCode] || messages.download;
      stop();
      throw new Error(lastError);
    } finally {
      preparing = false;
      clearTimeout(idle);
      if (worker) idle = setTimeout(stop, 120000);
    }
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
