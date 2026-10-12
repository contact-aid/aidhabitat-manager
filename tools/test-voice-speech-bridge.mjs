import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../aid_habitat_app/web/voice_speech_bridge.js', import.meta.url), 'utf8');

function createBrowser({ availability = 'available', prefixedOnly = false, unprefixedOnly = false, unsupported = false, legacy = false, localFallback = false } = {}) {
  const starts = [];
  const instances = [];
  const timers = new Map();
  let timerId = 0;
  let aborted = 0;
  let available = availability;
  class Recognition extends EventTarget {
    static async available() {
      if (available instanceof Error) throw available;
      if (available === 'pending') return new Promise(() => {});
      return available;
    }
    constructor() { super(); this.processLocally = false; instances.push(this); }
    dispatchEvent(event) {
      const result = super.dispatchEvent(event);
      this['on' + event.type]?.(event);
      return result;
    }
    start(...args) { starts.push({ args, local: this.processLocally, lang: this.lang }); }
    stop() {}
    abort() { aborted++; }
  }
  if (legacy) Recognition.available = undefined;
  const window = {};
  if (!unsupported) {
    if (!prefixedOnly) window.SpeechRecognition = Recognition;
    if (!unprefixedOnly) window.webkitSpeechRecognition = Recognition;
  }
  if (localFallback) {
    window.AidHabitatLocalSpeechRecognition = class extends Recognition {
      start() { starts.push({ localModel: true }); }
    };
  }
  runInNewContext(source, {
    window, Event, EventTarget,
    // No mediaDevices provided: speech must open its own input.
    setTimeout: (callback, delay) => { timers.set(++timerId, {callback, delay}); return timerId; },
    clearTimeout: id => timers.delete(id),
  });
  return {
    window, starts, timers, instances,
    get aborted() { return aborted; },
    setAvailability: value => { available = value; },
    fireTimers: delay => {
      for (const [id, timer] of [...timers]) {
        if (timer.delay === delay) { timers.delete(id); timer.callback(); }
      }
    },
  };
}

function emit(recognition, type, error) {
  const event = new Event(type);
  if (error) Object.defineProperty(event, 'error', {value: error});
  recognition.dispatchEvent(event);
}

for (const config of [{}, {prefixedOnly:true, legacy:true}, {unprefixedOnly:true}]) {
  test(`direct microphone startup supports constructor variants ${JSON.stringify(config)}`, async () => {
    const browser = createBrowser(config);
    const mode = await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR');
    assert.equal(mode, 'remote');
    const recognition = new browser.window.webkitSpeechRecognition();
    recognition.start();
    assert.equal(browser.starts.length, 1, 'Start is synchronous and takes no external audio track');
    assert.equal(browser.starts[0].args.length, 0);
    assert.equal(browser.starts[0].lang, 'fr-FR');
    emit(recognition, 'start');
    assert.equal(browser.timers.size, 0);
  });
}

for (const availability of ['unavailable', 'downloadable', 'downloading', new Error('Permissions policy denied')]) {
  test(`unavailable experimental local speech does not prevent browser speech (${String(availability)})`, async () => {
    const browser = createBrowser({availability});
    assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'remote');
    new browser.window.webkitSpeechRecognition().start();
    assert.equal(browser.starts[0].local, false);
  });
}

test('a stalled local availability check falls back without hanging the button', async () => {
  const browser = createBrowser({availability:'pending'});
  const preparation = browser.window.aidHabitatPrepareSpeechRecognition('fr-FR');
  browser.fireTimers(1500);
  assert.equal(await preparation, 'remote');
  assert.equal(browser.timers.size, 0);
});

test('retained plugin instance stays on stable browser speech when local fallback is unavailable', async () => {
  const browser = createBrowser();
  await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR');
  const recognition = new browser.window.webkitSpeechRecognition();
  recognition.start();
  emit(recognition, 'error', 'language-not-supported');
  emit(recognition, 'end');
  assert.equal(browser.starts.length, 1, 'Never restart the microphone without a new click');
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'remote');
  recognition.start();
  assert.equal(browser.starts[1].local, false);
});

test('silent termination reports an error, but stopping or successful dictation does not', async () => {
  const browser = createBrowser();
  await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR');
  const recognition = new browser.window.webkitSpeechRecognition();
  const errors = [];
  recognition.onerror = event => errors.push(event.error);
  recognition.start();
  emit(recognition, 'end');
  assert.deepEqual(errors, ['no-speech']);
  recognition.start();
  recognition.stop();
  emit(recognition, 'end');
  recognition.start();
  emit(recognition, 'result');
  emit(recognition, 'end');
  assert.deepEqual(errors, ['no-speech']);
  assert.equal(browser.timers.size, 0);
});

test('startup timeout reports the cause and releases recognition', async () => {
  const browser = createBrowser();
  await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR');
  const recognition = new browser.window.webkitSpeechRecognition();
  let error;
  recognition.onerror = event => { error = event.error; };
  recognition.start();
  browser.fireTimers(15000);
  assert.equal(error, 'start-timeout');
  assert.equal(browser.aborted, 1);
});

test('unsupported browser is identified before microphone startup', async () => {
  const browser = createBrowser({unsupported:true});
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'unsupported');
});


test('Firefox selects the local model without native SpeechRecognition', async () => {
  const browser = createBrowser({ unsupported: true, localFallback: true });
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'local-model');
  new browser.window.webkitSpeechRecognition().start();
  assert.equal(browser.starts[0].localModel, true);
  assert.equal(browser.timers.size, 0, 'Native startup timeout must not interrupt the model download');
});

for (const code of ['network', 'service-not-allowed', 'language-not-supported']) {
  test(`Chrome keeps selecting the local model after ${code}`, async () => {
    const browser = createBrowser({ localFallback: true });
    await browser.window.aidHabitatPrepareSpeechRecognition();
    const recognition = new browser.window.webkitSpeechRecognition();
    recognition.start();
    emit(recognition, 'error', code);
    emit(recognition, 'end');
    assert.equal(browser.starts.length, 1);
    assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition(), 'local-model');
    recognition.start();
    assert.equal(browser.starts[1].localModel, true);
    recognition.abort();
    assert.equal(browser.timers.size, 0);
  });
}


test('direct web callbacks deliver text before completion without plugin final timers', async () => {
  const b = createBrowser({ localFallback: true });
  await b.window.aidHabitatPrepareSpeechRecognition();
  const events = [];
  b.window.aidHabitatStartSpeechRecognition(text => events.push(text), status => events.push(status), error => events.push(error));
  const engine = b.instances.at(-1);
  emit(engine, 'start');
  emit(engine, 'speechend');
  const result = new Event('result');
  Object.defineProperty(result, 'results', {value: [[{transcript: 'marche avec une canne'}]]});
  engine.dispatchEvent(result);
  emit(engine, 'end');
  assert.deepEqual(events, ['listening', 'processing', 'marche avec une canne', 'done']);
});

test('cancelled web callbacks cannot insert text into a new editor', async () => {
  const b = createBrowser({ localFallback: true });
  await b.window.aidHabitatPrepareSpeechRecognition();
  const old = [], current = [];
  b.window.aidHabitatStartSpeechRecognition(value => old.push(value), status => old.push(status), error => old.push(error));
  const previous = b.instances.at(-1);
  b.window.aidHabitatCancelSpeechRecognition();
  b.window.aidHabitatStartSpeechRecognition(value => current.push(value), status => current.push(status), error => current.push(error));
  const result = new Event('result');
  Object.defineProperty(result, 'results', {value: [[{transcript: 'ancien texte'}]]});
  previous.dispatchEvent(result);
  emit(previous, 'end');
  assert.deepEqual(old, []);
  assert.deepEqual(current, []);
});
