#!/usr/bin/env node

import { realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const fullSha = /^[a-f0-9]{40}$/i;
const maxBodyBytes = 16 * 1024;

export class ApiReadinessError extends Error {
  constructor(code) {
    super(code);
    this.name = 'ApiReadinessError';
    this.code = code;
  }
}

export function validateReadinessConfig({ baseUrl, expectedSha, timeoutMs = 300000,
  requestTimeoutMs = 10000, pollIntervalMs = 5000 }) {
  let url;
  try { url = new URL(baseUrl); } catch { throw new ApiReadinessError('INVALID_API_HEALTH_ORIGIN'); }
  const loopback = ['127.0.0.1', '[::1]'].includes(url.hostname);
  if ((url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) ||
      url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new ApiReadinessError('INVALID_API_HEALTH_ORIGIN');
  }
  if (typeof expectedSha !== 'string' || !fullSha.test(expectedSha)) {
    throw new ApiReadinessError('INVALID_EXPECTED_BUILD_SHA');
  }
  for (const [value, max] of [[timeoutMs, 600000], [requestTimeoutMs, 30000], [pollIntervalMs, 30000]]) {
    if (!Number.isSafeInteger(value) || value <= 0 || value > max) {
      throw new ApiReadinessError('INVALID_READINESS_DEADLINE');
    }
  }
  return { baseUrl: url.origin, expectedSha: expectedSha.toLowerCase(), timeoutMs, requestTimeoutMs, pollIntervalMs };
}

// A deadline covers headers AND the streamed body, including an HTTP client
// that ignores AbortSignal. No URL, server body or transport error is logged.
async function probe(url, expectedStatus, config, remainingMs, runtime) {
  const controller = new AbortController();
  let timer;
  let reader;
  const deadline = new Promise((_, reject) => {
    timer = runtime.setTimeoutImpl(() => {
      controller.abort();
      reject(new ApiReadinessError('HEALTH_REQUEST_TIMEOUT'));
    }, Math.min(config.requestTimeoutMs, remainingMs));
  });
  try {
    return await Promise.race([deadline, (async () => {
      const response = await runtime.fetchImpl(url, {
        method: 'GET', redirect: 'manual', signal: controller.signal,
        cache: 'no-store', headers: { Accept: 'application/json', 'Cache-Control': 'no-cache' },
      });
      if (response.status >= 300 && response.status < 400 || response.redirected) {
        throw new ApiReadinessError('HEALTH_REDIRECT_REFUSED');
      }
      if (response.status !== 200) return false;
      if (!/^application\/json(?:\s*;|$)/i.test(response.headers.get('content-type') || '')) return false;
      reader = response.body?.getReader();
      if (!reader) return false;
      const chunks = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maxBodyBytes) throw new ApiReadinessError('HEALTH_BODY_TOO_LARGE');
        chunks.push(value);
      }
      let payload;
      try { payload = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return false; }
      return payload?.success === true && payload.status === expectedStatus &&
        payload.buildSha === config.expectedSha;
    })()]);
  } catch (error) {
    if (error instanceof ApiReadinessError && error.code === 'HEALTH_REDIRECT_REFUSED') throw error;
    return false;
  } finally {
    runtime.clearTimeoutImpl(timer);
    controller.abort();
    // Cancellation may itself never resolve on a broken/custom stream.
    if (reader) void reader.cancel().catch(() => {});
  }
}

export async function waitForApiReadiness(input, {
  fetchImpl = globalThis.fetch,
  now = () => performance.now(),
  setTimeoutImpl = globalThis.setTimeout,
  clearTimeoutImpl = globalThis.clearTimeout,
  sleep = (ms) => new Promise((resolve) => setTimeoutImpl(resolve, ms)),
} = {}) {
  const config = validateReadinessConfig(input);
  const runtime = { fetchImpl, setTimeoutImpl, clearTimeoutImpl };
  const deadline = now() + config.timeoutMs;
  let attempts = 0;
  while (now() < deadline) {
    attempts++;
    const live = await probe(`${config.baseUrl}/api/health/live`, 'live', config, deadline - now(), runtime);
    if (live && now() < deadline) {
      const ready = await probe(`${config.baseUrl}/api/health/ready`, 'ready', config, deadline - now(), runtime);
      if (ready && now() < deadline) return { buildSha: config.expectedSha, attempts };
    }
    const remaining = deadline - now();
    if (remaining > 0) await sleep(Math.min(config.pollIntervalMs, remaining));
  }
  throw new ApiReadinessError('API_READINESS_DEADLINE_EXCEEDED');
}

async function main() {
  const config = validateReadinessConfig({
    baseUrl: process.env.API_HEALTH_BASE_URL,
    expectedSha: process.env.EXPECTED_BUILD_SHA,
    timeoutMs: process.env.API_READINESS_TIMEOUT_MS === undefined ? 300000 : Number(process.env.API_READINESS_TIMEOUT_MS),
  });
  if (process.argv[2] === 'validate' && process.argv.length === 3) {
    console.log('API health configuration valid');
    return;
  }
  if (process.argv.length !== 2) throw new ApiReadinessError('INVALID_READINESS_ARGUMENTS');
  const result = await waitForApiReadiness(config);
  console.log(`API active SHA ${result.buildSha} and readiness verified (HTTP 200)`);
}

const isCli = process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
if (isCli) {
  main().catch((error) => {
    console.error(`[api-readiness] ${error instanceof ApiReadinessError ? error.code : 'API_READINESS_FAILED'}`);
    process.exitCode = 1;
  });
}
