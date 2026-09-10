import assert from 'node:assert/strict';
import test from 'node:test';
import { setImmediate } from 'node:timers/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { waitForApiReadiness, validateReadinessConfig } from './wait-api-readiness.mjs';

const sha = 'abcdef01'.repeat(5);
const oldSha = '1'.repeat(40);
const secret = 'SYNTHETIC_SECRET_DO_NOT_LOG';
const config = { baseUrl: 'https://api.test.invalid', expectedSha: sha,
  timeoutMs: 25, requestTimeoutMs: 10, pollIntervalMs: 5 };
const health = (status, buildSha = sha) => ({ success: true, status, buildSha });
const phase = (url) => url.endsWith('/live') ? 'live' : 'ready';

function response(payload, { status = 200, contentType = 'application/json', hang = false } = {}) {
  let read = false;
  const state = { cancelled: false };
  return {
    status, headers: new Headers({ 'content-type': contentType, location: `https://${secret}.invalid/` }),
    state,
    body: { getReader: () => ({
      read: async () => {
        if (hang) return new Promise(() => {});
        if (read) return { done: true };
        read = true;
        return { done: false, value: Buffer.from(typeof payload === 'string' ? payload : JSON.stringify(payload)) };
      },
      cancel: async () => { state.cancelled = true; },
    }) },
  };
}

// Virtual monotonic time makes deadline/body-hang tests independent of CPU speed.
function clock() {
  let time = 0;
  let nextId = 0;
  const timers = new Map();
  const runtime = {
    now: () => time,
    setTimeoutImpl: (callback, ms) => {
      const id = ++nextId;
      timers.set(id, { callback, at: time + ms });
      return id;
    },
    clearTimeoutImpl: (id) => timers.delete(id),
  };
  return { runtime, timers, now: runtime.now,
    async run(promise) {
      let settled = false;
      let result;
      let failure;
      promise.then((value) => { result = value; settled = true; }, (error) => { failure = error; settled = true; });
      for (let turn = 0; turn < 1000 && !settled; turn++) {
        await setImmediate();
        if (settled) break;
        const next = [...timers.entries()].sort((a, b) => a[1].at - b[1].at)[0];
        assert(next, 'Readiness became stuck without a deadline');
        time = next[1].at;
        timers.delete(next[0]);
        next[1].callback();
      }
      assert(settled, 'Readiness failed to settle within the virtual deadline');
      assert.equal(timers.size, 0, 'All request timers must be cleaned up');
      if (failure) throw failure;
      return result;
    },
  };
}

test('only matching live SHA AND matching ready HTTP 200 confirm deployment', async () => {
  const time = clock();
  const calls = [];
  let attempts = 0;
  const result = await time.run(waitForApiReadiness(config, { ...time.runtime,
    fetchImpl: async (url, options) => {
      calls.push(url);
      assert.equal(options.method, 'GET');
      assert.equal(options.redirect, 'manual');
      assert.equal(options.cache, 'no-store');
      assert.equal(options.headers.Authorization, undefined);
      if (phase(url) === 'live') attempts++;
      return response(health(phase(url), attempts === 1 ? oldSha : sha), {
        status: attempts === 2 && phase(url) === 'ready' ? 503 : 200,
      });
    },
  }));
  assert.deepEqual(result, { buildSha: sha, attempts: 3 });
  assert.deepEqual(calls.map(phase), ['live', 'live', 'ready', 'live', 'ready']);
  assert.equal(time.now(), 10);
});

for (const failure of ['wrong SHA', 'live 503', 'ready 503', 'old ready SHA', 'missing SHA', 'invalid JSON', 'HTML', 'false success']) {
  test(`${failure} never confirms deployment before the bounded deadline`, async () => {
    const time = clock();
    const calls = [];
    await assert.rejects(time.run(waitForApiReadiness(config, { ...time.runtime,
      fetchImpl: async (url) => {
        calls.push(phase(url));
        const payload = health(phase(url));
        if (failure === 'wrong SHA' || failure === 'old ready SHA' && phase(url) === 'ready') payload.buildSha = oldSha;
        if (failure === 'missing SHA') delete payload.buildSha;
        if (failure === 'false success') payload.success = false;
        return response(failure === 'invalid JSON' ? secret : payload, {
          status: failure === 'live 503' || failure === 'ready 503' && phase(url) === 'ready' ? 503 : 200,
          contentType: failure === 'HTML' ? 'text/html' : 'application/json',
        });
      },
    })), /^ApiReadinessError: API_READINESS_DEADLINE_EXCEEDED$/);
    assert.equal(time.now(), config.timeoutMs);
    if (failure === 'wrong SHA') assert(calls.every((call) => call === 'live'));
  });
}

for (const hangingPhase of ['fetch', 'live body', 'ready body']) {
  test(`${hangingPhase} ignoring AbortSignal still respects the overall deadline`, async () => {
    const time = clock();
    const signals = [];
    const bodies = [];
    await assert.rejects(time.run(waitForApiReadiness({ ...config, requestTimeoutMs: 30 }, { ...time.runtime,
      fetchImpl: async (url, options) => {
        signals.push(options.signal);
        if (hangingPhase === 'fetch') return new Promise(() => {});
        const body = response(health(phase(url)), { hang: hangingPhase === `${phase(url)} body` });
        bodies.push(body);
        return body;
      },
    })), /API_READINESS_DEADLINE_EXCEEDED/);
    assert.equal(time.now(), 25);
    assert(signals.every((signal) => signal.aborted));
    assert(bodies.every((body) => body.state.cancelled));
  });
}

for (const redirectPhase of ['live', 'ready']) {
  test(`${redirectPhase} redirect fails immediately without forwarding requests or leaking its Location`, async () => {
    const time = clock();
    const calls = [];
    await assert.rejects(time.run(waitForApiReadiness(config, { ...time.runtime,
      fetchImpl: async (url) => {
        calls.push(url);
        return response(phase(url) === redirectPhase ? secret : health(phase(url)), {
          status: phase(url) === redirectPhase ? 302 : 200,
        });
      },
    })), (error) => {
      assert.equal(error.code, 'HEALTH_REDIRECT_REFUSED');
      assert.doesNotMatch(String(error), new RegExp(secret));
      return true;
    });
    assert.equal(calls.length, redirectPhase === 'live' ? 1 : 2);
    assert.equal(time.now(), 0);
  });
}

test('network errors, including secret URLs, remain private', async () => {
  const time = clock();
  await assert.rejects(time.run(waitForApiReadiness(config, { ...time.runtime,
    fetchImpl: async () => { throw new Error(`https://user:${secret}@private.invalid/${secret}`); },
  })), (error) => {
    assert.equal(error.code, 'API_READINESS_DEADLINE_EXCEEDED');
    assert.doesNotMatch(String(error.stack), /https|user|private|SYNTHETIC_SECRET/);
    return true;
  });
});

test('oversized health body cannot confirm deployment', async () => {
  const time = clock();
  await assert.rejects(time.run(waitForApiReadiness(config, { ...time.runtime,
    fetchImpl: async (url) => response({ ...health(phase(url)), padding: 'x'.repeat(16384) }),
  })), /API_READINESS_DEADLINE_EXCEEDED/);
});

test('configuration rejects unsafe origins, incomplete SHA and unbounded timers without echoing inputs', () => {
  for (const baseUrl of [undefined, secret, `https://user:${secret}@api.invalid`,
    `https://api.invalid/${secret}`, `https://api.invalid?token=${secret}`, `https://api.invalid/#${secret}`,
    'http://api.invalid', 'file:///tmp/private']) {
    assert.throws(() => validateReadinessConfig({ ...config, baseUrl }), /^ApiReadinessError: INVALID_API_HEALTH_ORIGIN$/);
  }
  for (const expectedSha of ['', sha.slice(0, 12), 'f'.repeat(64), secret]) {
    assert.throws(() => validateReadinessConfig({ ...config, expectedSha }), /INVALID_EXPECTED_BUILD_SHA/);
  }
  for (const timeoutMs of [0, -1, Infinity, NaN, 600001, 0.5]) {
    assert.throws(() => validateReadinessConfig({ ...config, timeoutMs }), /INVALID_READINESS_DEADLINE/);
  }
  assert.equal(validateReadinessConfig({ ...config, expectedSha: sha.toUpperCase() }).expectedSha, sha);
});

test('real CLI exits nonzero on a local redirect and logs no secret URL or body', async (t) => {
  let requests = 0;
  const server = createServer((_req, res) => {
    requests++;
    res.writeHead(302, { Location: `http://127.0.0.1:${server.address().port}/${secret}` });
    res.end(secret);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));
  await assert.rejects(promisify(execFile)(process.execPath, [fileURLToPath(new URL('./wait-api-readiness.mjs', import.meta.url))], {
    env: { API_HEALTH_BASE_URL: `http://127.0.0.1:${server.address().port}`, EXPECTED_BUILD_SHA: sha },
    timeout: 5000,
  }), (error) => {
    assert.equal(error.code, 1);
    assert.equal(error.stdout, '');
    assert.match(error.stderr, /HEALTH_REDIRECT_REFUSED/);
    assert.doesNotMatch(error.stderr, /127\.0\.0\.1|http|SYNTHETIC_SECRET/);
    return true;
  });
  assert.equal(requests, 1);
});
