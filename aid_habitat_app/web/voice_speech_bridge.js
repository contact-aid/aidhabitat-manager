(function installAidHabitatSpeechBridge() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  let runtime = 'remote';
  let retryWithBrowserService = false;

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
    // speech_to_text keeps one recognition object after initialize(). Install
    // its constructor alias once; apply the CURRENT mode each time it starts.
    // This also supports browsers exposing only the unprefixed constructor.
    function BridgedSpeechRecognition() {
      const recognition = new Recognition();
      const nativeStart = recognition.start.bind(recognition);
      const nativeStop = recognition.stop.bind(recognition);
      const nativeAbort = recognition.abort.bind(recognition);
      let intentionalStop = false;
      let receivedResult = false;
      let failed = false;
      let localSession = false;
      let startTimer = null;
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
        if (localSession && ['language-not-supported', 'network', 'no-speech'].includes(event.error)) {
          retryWithBrowserService = true;
        }
      });
      recognition.addEventListener('end', function() {
        clearStartTimer();
        if (!receivedResult && !failed && !intentionalStop) {
          // Do not silently flash the microphone then return to idle.
          if (localSession) retryWithBrowserService = true;
          emitError('no-speech');
        }
      });
      recognition.start = function() {
        clearStartTimer();
        intentionalStop = false;
        receivedResult = false;
        failed = false;
        localSession = runtime === 'local';
        recognition.lang = 'fr-FR';
        if ('processLocally' in recognition) recognition.processLocally = localSession;
        window.__aidHabitatSpeechEvents = [];
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
        nativeStop();
      };
      recognition.abort = function() {
        intentionalStop = true;
        clearStartTimer();
        nativeAbort();
      };
      return recognition;
    }
    BridgedSpeechRecognition.prototype = Recognition.prototype;
    Object.defineProperty(window, 'webkitSpeechRecognition', {
      configurable: true, writable: true, value: BridgedSpeechRecognition,
    });
  }

  window.aidHabitatPrepareSpeechRecognition = async function(locale) {
    if (!Recognition) return setRuntime('unsupported');
    if (retryWithBrowserService || typeof Recognition.available !== 'function') {
      return setRuntime('remote');
    }
    let timeout;
    try {
      // Use an already-installed local language pack. A download, browser
      // policy denial or stalled experimental API must not block dictation.
      const availability = await Promise.race([
        Recognition.available({ langs: [locale], processLocally: true }),
        new Promise(resolve => { timeout = setTimeout(() => resolve('unavailable'), 1500); }),
      ]);
      return setRuntime(availability === 'available' ? 'local' : 'remote');
    } catch (_) {
      record('preparation', 'local-unavailable');
      return setRuntime('remote');
    } finally {
      clearTimeout(timeout);
    }
  };
})();
