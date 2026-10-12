(() => {
  let worker;
  let nextId = 0;
  let progress = 0;
  let idle;
  // Retain the loaded GPU model between edits; release after a bounded idle period.
  const warmIdleMs = 10 * 60 * 1000;
  let generation = 0;
  const pending = new Map();
  let preparing = false;
  let statusPending;
  let warming;
  let phase = '';
  let lastError = '';
  const messages = {
    storage: 'Le navigateur ne répond pas à la vérification du stockage. Fermez cette fenêtre et réessayez.',
    space: 'Espace insuffisant : prévoyez au moins 1,3 Go libres.',
    unsupported: 'L’IA locale nécessite WebGPU. Vérifiez que l’accélération graphique est activée dans votre navigateur.',
    gpu_limits: 'Ce navigateur ne fournit pas les capacités graphiques nécessaires au moteur d’IA local. Utilisez Google Chrome à jour pour installer et utiliser l’IA. Gardez votre rapport ouvert et vérifiez sa synchronisation avant de changer de navigateur. [GPU_LIMITS]',
    download: 'Le téléchargement ne répond pas. Vérifiez la connexion puis réessayez. Les notes sont conservées.',
    offline: 'Le modèle est prêt, mais la préparation hors ligne a échoué. Réessayez sans effacer les données du navigateur.',
    offline_optional: 'Le modèle d’IA est installé et utilisable dans ce navigateur. L’accès hors ligne à l’application n’a pas pu être préparé : gardez une connexion pour ouvrir l’application. Aucune protection ni donnée du dossier n’a été modifiée. [OFFLINE_SHELL]',
    model_network: 'Le navigateur n’a pas pu récupérer un fichier du modèle. Vérifiez la connexion et l’accès à Hugging Face, puis réessayez. [MODEL_NETWORK]',
    model_storage: 'Le navigateur n’a pas pu enregistrer le modèle dans son stockage local. Vérifiez l’espace libre et les autorisations de stockage du site. [MODEL_STORAGE]',
    model_gpu: 'Le moteur graphique n’a pas pu charger le modèle. Vérifiez la version du navigateur et l’accélération graphique. [MODEL_GPU]',
    model_runtime: 'Le moteur local n’a pas pu charger le modèle. Le téléchargement peut être partiel. Réessayez sans effacer les données du navigateur. [MODEL_RUNTIME]',
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
        if (data.phase !== undefined) { phase = data.phase; return; }
        if (data.progress !== undefined) { progress = data.progress; return; }
        const item = pending.get(data.id);
        if (!item) return;
        pending.delete(data.id);
        clearTimeout(item.timer);
        if (data.error) {
          const error = new Error(data.error);
          error.code = data.code;
          if (messages[data.code]) error.setupCode = data.code;
          item.reject(error);
        }
        else item.resolve(data.result);
        if (!pending.size && !preparing) idle = setTimeout(stop, warmIdleMs);
      };
      worker.onerror = stop;
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(stop, method === 'prepare' ? 1800000 : method === 'status' ? 15000 : 600000);
      pending.set(id, {resolve, reject, timer});
      worker.postMessage({id, method, ...payload});
    });
  }
  async function readStatus() {
    const attempt = generation;
    if (!window.isSecureContext || !navigator.gpu || !navigator.serviceWorker) {
      return JSON.stringify({supported: false, installed: false});
    }
    const result = await request('status');
    if (result.reason === 'gpu_limits') result.message = messages.gpu_limits;
    const registration = await navigator.serviceWorker.getRegistration();
    result.installed = result.installed && localStorage.getItem('appergo-local-ai-qwen3-v1') === 'complete';
    result.offlineReady = !!registration?.active?.scriptURL.endsWith('/ai_offline_worker.js');
    // Warm only an explicitly installed model, without note or network access.
    // Clicks join this load so mounting several editors cannot load twice.
    if (attempt === generation && result.installed && !result.ready && !preparing && !warming) {
      warming = request('warmup').catch(() => {}).finally(() => { warming = undefined; });
    }
    return JSON.stringify(result);
  }
  window.aidHabitatLocalAiStatus = () => {
    if (!statusPending) statusPending = readStatus().finally(() => { statusPending = undefined; });
    return statusPending;
  };
  window.aidHabitatLocalAiProgress = () => progress;
  window.aidHabitatLocalAiCancel = stop;
  window.aidHabitatLocalAiPrepare = async () => {
    const attempt = generation;
    let modelReady = false;
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
    if (!state.supported) { const code = state.reason === 'gpu_limits' ? 'gpu_limits' : 'unsupported'; const error = new Error(messages[code]); error.setupCode = code; throw error; }
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
    modelReady = result.ready === true;
    clearTimeout(idle);
    checkCancelled();
    // Explicit opt-in; this worker caches only a build-time list of static files.
    phase = 'Préparation de l’accès hors ligne…';
    const registration = await deadline(navigator.serviceWorker.register('ai_offline_worker.js', {updateViaCache: 'none'}), 30000, 'offline');
    await deadline(registration.update(), 30000, 'offline');
    const installing = registration.installing || registration.waiting;
    if (installing && installing.state !== 'activated') {
      await deadline(new Promise((resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error('Preparation hors ligne incomplete.')), 180000);
        const checkState = () => {
          if (installing.state === 'activated') { clearTimeout(timeout); resolve(); }
          if (installing.state === 'redundant') { clearTimeout(timeout); reject(new Error('Preparation hors ligne impossible.')); }
        };
        installing.addEventListener('statechange', checkState);
        checkState();
      }), 180000, 'offline');
    }
    checkCancelled();
    localStorage.setItem('appergo-local-ai-qwen3-v1', 'complete');
    idle = setTimeout(stop, warmIdleMs);
    phase = 'Installation terminée';
    return JSON.stringify(result);
    } catch (error) {
      if (modelReady && attempt === generation && error.setupCode === 'offline') {
        // A modified or unavailable static shell must fail its integrity
        // checks. That does not undo a completely installed local model.
        localStorage.setItem('appergo-local-ai-qwen3-v1', 'complete');
        lastError = messages.offline_optional;
        phase = 'Installation du modèle terminée';
        return JSON.stringify({supported: true, installed: true, ready: true, offlineReady: false, warning: lastError});
      }
      lastError = messages[error.setupCode] || messages.download;
      stop();
      throw new Error(lastError);
    } finally {
      preparing = false;
      clearTimeout(idle);
      if (worker) idle = setTimeout(stop, warmIdleMs);
    }
  };
  window.aidHabitatLocalAiRewrite = async (text, mode, context) => {
    const attempt = generation;
    try {
      if (warming) await warming;
      if (attempt !== generation) throw new Error('Reformulation annulée.');
      phase = 'Préparation de la reformulation…';
      return await request('rewrite', {text, mode, context});
    }
    catch (error) {
      if (error.code === 'model_unavailable') localStorage.removeItem('appergo-local-ai-qwen3-v1');
      throw error;
    }
  };
  window.addEventListener('pagehide', stop);
})();
