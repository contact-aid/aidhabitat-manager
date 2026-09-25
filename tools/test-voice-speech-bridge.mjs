import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { runInNewContext } from 'node:vm';

const source = readFileSync(
  new URL('../aid_habitat_app/web/voice_speech_bridge.js', import.meta.url),
  'utf8',
);

function createBrowser({ localAvailable = true, arc = false } = {}) {
  const starts = [];
  let microphoneRequests = 0;
  class Recognition {
    static async available() {
      return localAvailable ? 'available' : 'unavailable';
    }

    static async install() {
      return true;
    }

    constructor() {
      this.listeners = new Map();
    }

    addEventListener(type, callback) {
      this.listeners.set(type, callback);
    }

    start(...args) {
      starts.push(args);
    }

    stop() {}
    abort() {}
  }

  const storage = new Map();
  const window = {
    SpeechRecognition: Recognition,
    webkitSpeechRecognition: Recognition,
    getComputedStyle: () => ({
      getPropertyValue: () => (arc ? '#123456' : ''),
    }),
    sessionStorage: {
      getItem: (key) => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
    },
  };
  const navigator = {
    mediaDevices: {
      getUserMedia: async () => {
        microphoneRequests += 1;
        return {
          getAudioTracks: () => [{ kind: 'audio', readyState: 'live' }],
          getTracks: () => [],
        };
      },
    },
  };
  runInNewContext(source, { window, document: { documentElement: {} }, navigator });
  return { window, starts, get microphoneRequests() { return microphoneRequests; } };
}

test('Chrome local recognition opens its own microphone synchronously', async () => {
  const browser = createBrowser();
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'local');
  const recognition = new browser.window.webkitSpeechRecognition();
  recognition.start();
  assert.equal(browser.starts.length, 1);
  assert.equal(browser.starts[0].length, 0);
  assert.equal(browser.microphoneRequests, 0);
  assert.equal(recognition.processLocally, true);
});

test('Chrome remote fallback also opens its own microphone', async () => {
  const browser = createBrowser({ localAvailable: false });
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'remote');
  new browser.window.webkitSpeechRecognition().start();
  assert.equal(browser.starts.length, 1);
  assert.equal(browser.starts[0].length, 0);
  assert.equal(browser.microphoneRequests, 0);
});

test('Arc keeps its explicit microphone track', async () => {
  const browser = createBrowser({ arc: true });
  assert.equal(await browser.window.aidHabitatPrepareSpeechRecognition('fr-FR'), 'remote-track');
  new browser.window.webkitSpeechRecognition().start();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(browser.microphoneRequests, 1);
  assert.equal(browser.starts.length, 1);
  assert.equal(browser.starts[0][0].kind, 'audio');
});
