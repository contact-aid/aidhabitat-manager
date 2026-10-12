(() => {
  const status = document.getElementById('status'), result = document.getElementById('result');
  const install = document.getElementById('install'), cancel = document.getElementById('cancel'), progress = document.getElementById('progress');
  let timer, busy = false;
  const finish = () => { clearInterval(timer); busy = false; cancel.hidden = true; install.disabled = false; };
  install.addEventListener('click', async () => {
    if (busy) return;
    busy = true; install.disabled = true; cancel.hidden = false; progress.hidden = false; progress.removeAttribute('value');
    status.textContent = 'Démarrage du téléchargement…'; result.textContent = '';
    timer = setInterval(() => {
      status.textContent = aidHabitatLocalAiPhase() || 'Préparation du modèle…';
      const value = aidHabitatLocalAiProgress();
      if (value > 0 && value < 1) progress.value = value; else progress.removeAttribute('value');
    }, 500);
    try {
      await aidHabitatLocalAiPrepare();
      finish(); install.hidden = true; progress.value = 1;
      status.textContent = 'Installation terminée. Vous pouvez revenir à votre rapport.';
    } catch (_) {
      finish(); progress.hidden = true; status.textContent = 'Installation interrompue';
      result.textContent = aidHabitatLocalAiLastError() || 'Réessayez. Les notes de votre dossier sont conservées.';
    }
  });
  cancel.addEventListener('click', () => aidHabitatLocalAiCancel());
  aidHabitatLocalAiStatus().then(raw => {
    const state = JSON.parse(raw);
    install.disabled = !state.supported;
    status.textContent = !state.supported ? 'Ce navigateur ne propose pas WebGPU. Vérifiez l’accélération graphique dans Chrome.' : state.installed ? 'Le modèle est déjà installé dans ce navigateur.' : 'Le navigateur est compatible. Cliquez sur Télécharger.';
  }).catch(() => { install.disabled = false; status.textContent = 'Cliquez sur Télécharger pour vérifier et installer le modèle.'; });
})();
