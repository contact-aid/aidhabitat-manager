import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';
const source = readFileSync(new URL('../aid_habitat_app/web/voice_local_recognition.js', import.meta.url), 'utf8');
const flush = async () => { for (let i = 0; i < 12; i++) await Promise.resolve(); };
function browser({ denied = false, pendingPermission = false, silence = false, mime = 'audio/webm;codecs=opus' } = {}) {
  const messages = [], recorders = [], timers = new Map();
  let timerId = 0, stopped = 0, closed = 0, resolvePermission;
  const stream = { getTracks: () => [{ stop() { stopped++; } }] };
  class AudioContext {
    resume() { return Promise.resolve(); }
    close() { closed++; return Promise.resolve(); }
    async decodeAudioData() {
      return { duration: 1, sampleRate: 48000, numberOfChannels: 2,
        getChannelData: () => new Float32Array(48000).fill(silence ? 0 : 0.5) };
    }
  }
  class MediaRecorder {
    static isTypeSupported(type) { return type === mime; }
    constructor(_stream, options) { recorders.push(this); this.mimeType = options.mimeType; this.state = 'inactive'; }
    start() { this.state = 'recording'; }
    stop() {
      this.state = 'inactive';
      queueMicrotask(() => {
        this.ondataavailable({ data: new Blob(['fixture']) });
        this.onstop();
      });
    }
  }
  class Worker {
    constructor() { this.terminated = false; }
    postMessage(data) {
      messages.push(data);
      queueMicrotask(() => this.onmessage({ data: { id: data.id, text: data.audio ? 'marche avec une canne' : '' } }));
    }
    terminate() { this.terminated = true; }
  }
  const window = { AudioContext, MediaRecorder, location: { href: 'https://app.aidhabitat.fr/' },
    navigator: { mediaDevices: { getUserMedia() {
      if (denied) return Promise.reject(Object.assign(new Error(), { name: 'NotAllowedError' }));
      if (pendingPermission) return new Promise(resolve => { resolvePermission = resolve; });
      return Promise.resolve(stream);
    } } } };
  runInNewContext(source, { window, document: { baseURI: window.location.href }, Event, EventTarget, Worker, Blob, URL, Float32Array,
    setTimeout: (callback, delay) => { timers.set(++timerId, { callback, delay }); return timerId; },
    clearTimeout: id => timers.delete(id) });
  const recognition = new window.AidHabitatLocalSpeechRecognition();
  const events = [];
  for (const type of ['start', 'result', 'error', 'end']) recognition.addEventListener(type, event => events.push({ type, event }));
  return { recognition, events, recorders, messages, timers, get stopped() { return stopped; }, get closed() { return closed; },
    resolvePermission() { resolvePermission(stream); },
    fire(delay) { for (const [id, timer] of [...timers]) if (timer.delay === delay) { timers.delete(id); timer.callback(); } } };
}
for (const mime of ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus']) {
  test(`records and transcribes French locally with ${mime}`, async () => {
    const b = browser({ mime });
    b.recognition.start();
    await flush();
    assert.deepEqual(b.events.map(e => e.type), ['start']);
    assert.equal(b.recorders[0].mimeType, mime);
    b.recognition.stop();
    await flush();
    assert.deepEqual(b.events.map(e => e.type), ['start', 'result', 'end']);
    assert.equal(b.events[1].event.results.item(0).item(0).transcript, 'marche avec une canne');
    const audio = b.messages.find(message => message.audio).audio;
    assert.equal(audio.length, 16000);
    assert.equal(audio[0], 0.5, 'Stereo is mixed and resampled to 16 kHz');
    assert.ok(b.stopped > 0);
    assert.equal(b.closed, 1);
    assert.equal(b.timers.size, 0);
  });
}
test('permission refusal releases the audio context and reports an actionable code', async () => {
  const b = browser({ denied: true }); b.recognition.start(); await flush();
  assert.deepEqual(b.events.map(e => e.type), ['error', 'end']);
  assert.equal(b.events[0].event.error, 'not-allowed');
  assert.equal(b.closed, 1);
  assert.equal(b.messages.length, 0, 'No model download before microphone permission');
});
test('cancelling a pending permission request releases late microphone tracks', async () => {
  const b = browser({ pendingPermission: true }); b.recognition.start(); b.recognition.abort();
  b.resolvePermission(); await flush();
  assert.deepEqual(b.events.map(e => e.type), ['end']);
  assert.equal(b.stopped, 1);
  assert.equal(b.closed, 1);
});
test('cancelled recorder results cannot insert text into the next editor', async () => {
  const b = browser(); b.recognition.start(); await flush(); b.recognition.abort(); await flush();
  assert.deepEqual(b.events.map(e => e.type), ['start', 'end']);
  assert.equal(b.messages.filter(m => m.audio).length, 0);
});
test('silence does not generate an invented transcript', async () => {
  const b = browser({ silence: true }); b.recognition.start(); await flush(); b.recognition.stop(); await flush();
  assert.deepEqual(b.events.map(e => e.type), ['start', 'error', 'end']);
  assert.equal(b.events[1].event.error, 'no-speech');
  assert.equal(b.messages.filter(m => m.audio).length, 0);
});
test('a one-minute recording ends automatically and inserts its transcript', async () => {
  const b = browser(); b.recognition.start(); await flush(); b.fire(60000); await flush();
  assert.deepEqual(b.events.map(e => e.type), ['start', 'result', 'end']);
});
