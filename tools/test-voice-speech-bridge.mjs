import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../aid_habitat_app/web/voice_speech_bridge.js', import.meta.url), 'utf8');

function createBrowser({ availability = 'available', prefixedOnly = false, unprefixedOnly = false, unsupported = false, legacy = false } = {}) {
  const starts = [];
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
    constructor() { super(); this.processLocally = false; }
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
  runInNewContext(source, {
    window, Event,
    // No mediaDevices provided: speech must open its own input.
    setTimeout: (callback, delay) => { timers.set(++timerId, {callback, delay}); return timerId; },
    clearTimeout: id => timers.delete(id),
  });
  return {
    window, starts, timers,
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
    assert.equal(mode, config.legacy ? 'remote' : 'local');
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
});

test('retained plugin instance changes mode on the NEXT user start after a local failure', async () => {
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
