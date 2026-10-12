(function installAidHabitatSpeechBridge() {
  const NativeRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  const LocalRecognition = window.AidHabitatLocalSpeechRecognition;
  const Recognition = NativeRecognition || LocalRecognition;
  let runtime = 'remote';

  function setRuntime(value) {
    runtime = value;
    window.__aidHabitatSpeechRuntime = value;
    return value;
  }

  function record(type, error) {
    // Diagnostics contain event names/codes only, never audio or transcripts.
    const events = window.__aidHabitatSpeechEvents || [];
    events.push(type + (error ? ':' + error : ''));
    window.__aidHabitatSpeechEvents = events.slice(-30);
  }

  if (Recognition) {
    // Keep the legacy constructor alias compatible while the web lifecycle
    // below routes results directly to Dart without native-plugin timers.
    function BridgedSpeechRecognition() {
      const recognition = new Recognition();
      const nativeStart = recognition.start.bind(recognition);
      const nativeStop = recognition.stop.bind(recognition);
      const nativeAbort = recognition.abort.bind(recognition);
      let intentionalStop = false;
      let receivedResult = false;
      let failed = false;
      let startTimer = null;
      let fallback = null;
      const clearStartTimer = function() {
        clearTimeout(startTimer);
        startTimer = null;
      };
      const emitError = function(code) {
        const event = new Event('error');
        Object.defineProperty(event, 'error', { value: code });
        recognition.dispatchEvent(event);
      };
      ['start', 'audiostart', 'soundstart', 'speechstart', 'result',
        'speechend', 'soundend', 'audioend', 'error', 'end'].forEach(function(type) {
        recognition.addEventListener(type, function(event) { record(type, event.error); });
      });
      recognition.addEventListener('start', clearStartTimer);
      recognition.addEventListener('result', function() { receivedResult = true; });
      recognition.addEventListener('error', function(event) {
        clearStartTimer();
        failed = true;
      });
      recognition.addEventListener('end', function() {
        clearStartTimer();
        if (!receivedResult && !failed && !intentionalStop) {
          // Do not silently flash the microphone then return to idle.
          emitError('no-speech');
        }
      });
      recognition.start = function() {
        clearStartTimer();
        intentionalStop = false;
        receivedResult = false;
        failed = false;
        recognition.lang = 'fr-FR';
        if ('processLocally' in recognition) recognition.processLocally = false;
        window.__aidHabitatSpeechEvents = [];
        if (NativeRecognition && runtime === 'local-model' && LocalRecognition) {
          fallback = new LocalRecognition();
          ['start', 'speechend', 'result', 'error', 'end'].forEach(function(type) {
            fallback.addEventListener(type, function(source) {
              const event = new Event(type);
              if (type === 'result') {
                Object.defineProperty(event, 'results', { value: source.results });
                Object.defineProperty(event, 'resultIndex', { value: source.resultIndex });
              }
              if (type === 'error') Object.defineProperty(event, 'error', { value: source.error });
              recognition.dispatchEvent(event);
            });
          });
          fallback.start();
          return;
        }
        fallback = null;
        // The local recorder owns its bounded model preparation and capture
        // timers. The native startup deadline must not interrupt its download.
        if (!NativeRecognition) { nativeStart(); return; }
        startTimer = setTimeout(function() {
          startTimer = null;
          emitError('start-timeout');
          nativeAbort();
        }, 15000);
        try {
          // The recognizer requests and owns its microphone directly. Opening
          // then closing getUserMedia first can lose the click activation or
          // leave the input busy. Passing an audio track is not portable.
          nativeStart();
        } catch (error) {
          clearStartTimer();
          throw error;
        }
      };
      recognition.stop = function() {
        intentionalStop = true;
        clearStartTimer();
        if (fallback) fallback.stop();
        else nativeStop();
      };
      recognition.abort = function() {
        intentionalStop = true;
        clearStartTimer();
        if (fallback) fallback.abort();
        else nativeAbort();
      };
      return recognition;
    }
    BridgedSpeechRecognition.prototype = Recognition.prototype;
    Object.defineProperty(window, 'webkitSpeechRecognition', {
      configurable: true, writable: true, value: BridgedSpeechRecognition,
    });
  }

  window.aidHabitatPrepareSpeechRecognition = async function() {
    if (!Recognition) return setRuntime('unsupported');
    // Do not await an experimental language-pack probe before microphone
    // startup: it can lose Safari's tap activation or select a broken engine.
    return setRuntime(LocalRecognition ? 'local-model' : 'remote');
  };

  let active;
  window.aidHabitatStartSpeechRecognition = function(onResult, onStatus, onError) {
    window.aidHabitatCancelSpeechRecognition();
    const recognition = active = new window.webkitSpeechRecognition();
    recognition.lang = 'fr-FR';
    recognition.interimResults = true;
    recognition.continuous = true;
    recognition.onstart = function() { if (active === recognition) onStatus('listening'); };
    recognition.onspeechend = function() { if (active === recognition) onStatus('processing'); };
    recognition.onresult = function(event) {
      if (active !== recognition) return;
      let transcript = '';
      for (let i = 0; i < event.results.length; i++) transcript += event.results[i][0].transcript + ' ';
      onResult(transcript.trim());
    };
    recognition.onerror = function(event) {
      if (active !== recognition) return;
      onError(event.error);
      // Release permission and pending transcription even if the browser
      // does not emit end after an error. Old callbacks cannot reach an editor.
      if (active === recognition) window.aidHabitatCancelSpeechRecognition();
    };
    recognition.onend = function() {
      if (active !== recognition) return;
      active = null;
      onStatus('done');
    };
    recognition.start();
  };
  window.aidHabitatStopSpeechRecognition = function() { active?.stop(); };
  window.aidHabitatCancelSpeechRecognition = function() {
    const previous = active;
    active = null;
    previous?.abort();
  };
})();
