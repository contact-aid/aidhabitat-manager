(function installLocalDictation() {
  const supported = !!(window.navigator?.mediaDevices?.getUserMedia && window.MediaRecorder && window.AudioContext);
  if (!supported) return;
  let worker;
  let nextId = 0;
  const requests = new Map();
  function releaseWorker() {
    worker?.terminate();
    worker = null;
    for (const { reject, timer } of requests.values()) {
      clearTimeout(timer);
      reject(new Error('local-model-unavailable'));
    }
    requests.clear();
  }
  function requestModel(audio) {
    if (!worker) {
      worker = new Worker(new URL('local-voice/worker.js', document.baseURI), { type: 'module' });
      worker.onmessage = ({ data }) => {
        const pending = requests.get(data.id);
        if (!pending) return;
        requests.delete(data.id);
        clearTimeout(pending.timer);
        if (data.error) pending.reject(new Error(data.error));
        else pending.resolve(data.text);
      };
      worker.onerror = releaseWorker;
    }
    return new Promise((resolve, reject) => {
      const id = ++nextId;
      const timer = setTimeout(releaseWorker, 180000);
      requests.set(id, { resolve, reject, timer });
      worker.postMessage({ id, audio }, audio ? [audio.buffer] : []);
    });
  }
  function emit(target, type, properties = {}) {
    const event = new Event(type);
    for (const [key, value] of Object.entries(properties)) Object.defineProperty(event, key, { value });
    target.dispatchEvent(event);
  }
  class LocalRecognition extends EventTarget {
    constructor() { super(); this.session = 0; this.active = false; }
    dispatchEvent(event) {
      const result = super.dispatchEvent(event);
      this['on' + event.type]?.(event);
      return result;
    }
    start() {
      if (this.active) throw new Error('recognition-already-started');
      this.active = true;
      this.startSession(++this.session);
    }
    async startSession(session) {
      try {
        // Resume audio and request permission synchronously in the user's tap.
        this.context = new window.AudioContext();
        const resumed = this.context.resume();
        // Permission prompts may stay open longer than a rejected resume.
        // Mark it handled now; Promise.all below still propagates the failure.
        resumed.catch(() => {});
        const microphone = window.navigator.mediaDevices.getUserMedia({ audio: true });
        this.timer = setTimeout(() => this.fail(session, 'local-model-unavailable'), 180000);
        const stream = await microphone;
        if (session !== this.session || !this.active) {
          stream.getTracks().forEach(track => track.stop());
          return;
        }
        this.stream = stream;
        await Promise.all([resumed, requestModel()]);
        if (session !== this.session || !this.active) return;
        clearTimeout(this.timer);
        const mimeType = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus']
          .find(type => window.MediaRecorder.isTypeSupported(type));
        const recorder = this.recorder = new window.MediaRecorder(stream, mimeType ? { mimeType } : {});
        const chunks = [];
        let bytes = 0;
        recorder.ondataavailable = ({ data }) => {
          if (session !== this.session || !this.active || !data.size) return;
          bytes += data.size;
          if (bytes > 10 * 1024 * 1024) this.fail(session, 'recording-too-large');
          else chunks.push(data);
        };
        recorder.onerror = () => this.fail(session, 'audio-capture');
        recorder.onstop = () => this.transcribe(session, recorder, chunks);
        recorder.start(1000);
        this.timer = setTimeout(() => this.stop(), 60000);
        emit(this, 'start');
      } catch (error) {
        const code = ['NotAllowedError', 'SecurityError'].includes(error.name) ? 'not-allowed'
          : ['NotFoundError', 'NotReadableError'].includes(error.name) ? 'audio-capture' : 'local-model-unavailable';
        this.fail(session, code);
      }
    }
    async transcribe(session, recorder, chunks) {
      // Check ownership before touching shared resources: an aborted recorder
      // may emit `stop` after the next dictation has already acquired its input.
      if (session !== this.session || !this.active) return;
      this.releaseMicrophone();
      emit(this, 'speechend');
      try {
        const blob = new Blob(chunks, { type: recorder.mimeType });
        if (!blob.size) throw new Error('no-speech');
        const context = this.context;
        const decoded = await context.decodeAudioData(await blob.arrayBuffer());
        if (session !== this.session || !this.active) return;
        const samples = new Float32Array(Math.floor(decoded.duration * 16000));
        for (let channel = 0; channel < decoded.numberOfChannels; channel++) {
          const input = decoded.getChannelData(channel);
          for (let i = 0; i < samples.length; i++) {
            const position = i * decoded.sampleRate / 16000;
            const index = Math.floor(position);
            const fraction = position - index;
            samples[i] += ((input[index] || 0) * (1 - fraction) + (input[index + 1] || 0) * fraction) / decoded.numberOfChannels;
          }
        }
        if (!samples.some(value => Math.abs(value) > 0.01)) throw new Error('no-speech');
        const text = await requestModel(samples);
        if (session !== this.session || !this.active) return;
        if (!text) throw new Error('no-speech');
        const result = [{ transcript: text, confidence: 1 }];
        result.isFinal = true;
        result.item = index => result[index];
        const results = [result];
        results.item = index => results[index];
        emit(this, 'result', { results, resultIndex: 0 });
        this.finish(session);
      } catch (error) {
        this.fail(session, error.message === 'no-speech' ? 'no-speech' : 'local-transcription-failed');
      }
    }
    releaseMicrophone() {
      this.stream?.getTracks().forEach(track => track.stop());
      this.stream = null;
    }
    finish(session) {
      if (session !== this.session || !this.active) return;
      this.active = false;
      clearTimeout(this.timer);
      this.releaseMicrophone();
      this.context?.close().catch(() => {});
      this.context = null;
      this.recorder = null;
      emit(this, 'end');
    }
    fail(session, code) {
      if (session !== this.session || !this.active) return;
      emit(this, 'error', { error: code });
      this.abort();
    }
    stop() {
      clearTimeout(this.timer);
      if (this.recorder?.state === 'recording') this.recorder.stop();
      else if (!this.recorder) this.abort();
    }
    abort() {
      const session = this.session;
      if (this.recorder?.state === 'recording') this.recorder.stop();
      this.finish(session);
      ++this.session;
    }
  }
  window.AidHabitatLocalSpeechRecognition = LocalRecognition;
})();
