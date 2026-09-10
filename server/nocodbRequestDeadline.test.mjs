import assert from 'node:assert/strict';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

import {
  DEFAULT_NOCODB_REST_TIMEOUT_MS,
  NocodbRestTimeoutError,
  fetchNocodbRestWithDeadline,
  parseNocodbRestTimeoutMs,
  shouldFallbackToRestAfterMcpError,
} from './nocodbRequestDeadline.mjs';

const createTimerHarness = () => {
  let callback;
  let delay;
  let clearCount = 0;
  const timeoutId = Symbol('timeout');

  return {
    setTimeoutImpl(nextCallback, nextDelay) {
      assert.equal(callback, undefined, 'un seul timer doit etre cree');
      callback = nextCallback;
      delay = nextDelay;
      return timeoutId;
    },
    clearTimeoutImpl(receivedId) {
      assert.equal(receivedId, timeoutId);
      clearCount += 1;
    },
    fire() {
      assert.equal(typeof callback, 'function');
      callback();
    },
    get clearCount() {
      return clearCount;
    },
    get delay() {
      return delay;
    },
  };
};

const requestWithHarness = (fetchImpl, timer) => fetchNocodbRestWithDeadline(
  new URL('https://nocodb.invalid/api/v2/tables/table-1/records'),
  { method: 'POST', body: '{"name":"test"}' },
  {
    timeoutMs: 5_000,
    method: 'POST',
    path: '/api/v2/tables/table-1/records',
    fetchImpl,
    setTimeoutImpl: timer.setTimeoutImpl,
    clearTimeoutImpl: timer.clearTimeoutImpl,
  },
);

test('configuration : valeur par defaut et bornes valides', () => {
  assert.equal(parseNocodbRestTimeoutMs(undefined), DEFAULT_NOCODB_REST_TIMEOUT_MS);
  assert.equal(parseNocodbRestTimeoutMs(''), DEFAULT_NOCODB_REST_TIMEOUT_MS);
  assert.equal(parseNocodbRestTimeoutMs(' 120000 '), 120_000);
  assert.equal(parseNocodbRestTimeoutMs('1000'), 1_000);
  assert.equal(parseNocodbRestTimeoutMs('900000'), 900_000);
});

test('configuration : les valeurs invalides sont refusees explicitement', () => {
  for (const value of ['0', '999', '900001', '1.5', 'abc', '-1000', 'Infinity']) {
    assert.throws(
      () => parseNocodbRestTimeoutMs(value),
      (error) => error?.code === 'NOCODB_REST_TIMEOUT_CONFIG_INVALID',
      `valeur qui aurait du etre refusee : ${value}`,
    );
  }
});

test('reponse normale : fetch et corps sont lus une fois puis le timer est nettoye', async () => {
  const timer = createTimerHarness();
  let fetchCount = 0;
  let bodyReadCount = 0;
  let receivedSignal;

  const result = await requestWithHarness(async (_url, options) => {
    fetchCount += 1;
    receivedSignal = options.signal;
    return {
      status: 200,
      async text() {
        bodyReadCount += 1;
        return '{"ok":true}';
      },
    };
  }, timer);

  assert.equal(result.response.status, 200);
  assert.equal(result.text, '{"ok":true}');
  assert.equal(fetchCount, 1);
  assert.equal(bodyReadCount, 1);
  assert.equal(receivedSignal.aborted, false);
  assert.equal(timer.delay, 5_000);
  assert.equal(timer.clearCount, 1);
});

test('fetch bloque : la requete est annulee, echoue en timeout et ne retente pas', async () => {
  const timer = createTimerHarness();
  let fetchCount = 0;
  let receivedSignal;

  const pendingRequest = requestWithHarness((_url, options) => {
    fetchCount += 1;
    receivedSignal = options.signal;
    return new Promise((_resolve, reject) => {
      options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
    });
  }, timer);

  timer.fire();

  await assert.rejects(
    pendingRequest,
    (error) => error instanceof NocodbRestTimeoutError
      && error.code === 'NOCODB_REST_TIMEOUT'
      && error.timeoutMs === 5_000,
  );
  assert.equal(fetchCount, 1);
  assert.equal(receivedSignal.aborted, true);
  assert.equal(timer.clearCount, 1);
});

test('corps bloque : la meme deadline annule aussi la lecture du corps', async () => {
  const timer = createTimerHarness();
  let fetchCount = 0;
  let bodyReadCount = 0;
  let receivedSignal;

  const pendingRequest = requestWithHarness(async (_url, options) => {
    fetchCount += 1;
    receivedSignal = options.signal;
    return {
      status: 200,
      text() {
        bodyReadCount += 1;
        return new Promise((_resolve, reject) => {
          options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
        });
      },
    };
  }, timer);

  await Promise.resolve();
  timer.fire();

  await assert.rejects(pendingRequest, { code: 'NOCODB_REST_TIMEOUT' });
  assert.equal(fetchCount, 1);
  assert.equal(bodyReadCount, 1);
  assert.equal(receivedSignal.aborted, true);
  assert.equal(timer.clearCount, 1);
});

test('erreur reseau : erreur intacte, une tentative et timer nettoye', async () => {
  const timer = createTimerHarness();
  const networkError = new Error('socket closed');
  let fetchCount = 0;

  await assert.rejects(
    requestWithHarness(async () => {
      fetchCount += 1;
      throw networkError;
    }, timer),
    (error) => error === networkError,
  );

  assert.equal(fetchCount, 1);
  assert.equal(timer.clearCount, 1);
});

test('fetch ignorant le signal : la deadline libere quand meme l appelant', async () => {
  const timer = createTimerHarness();
  let rejectLate;
  const pendingRequest = requestWithHarness(() => new Promise((_, reject) => {
    rejectLate = reject;
  }), timer);
  timer.fire();
  await assert.rejects(pendingRequest, { code: 'NOCODB_REST_TIMEOUT' });
  assert.equal(timer.clearCount, 1);
  // Promise.race must also consume a late rejection after the caller timed out.
  rejectLate(new Error('late network failure'));
  await new Promise((resolve) => setImmediate(resolve));
});

test('erreur de lecture du corps : erreur intacte et timer nettoye', async () => {
  const timer = createTimerHarness();
  const bodyError = new Error('body stream failed');

  await assert.rejects(
    requestWithHarness(async () => ({
      status: 200,
      async text() {
        throw bodyError;
      },
    }), timer),
    (error) => error === bodyError,
  );

  assert.equal(timer.clearCount, 1);
});

test('fallback MCP : aucun second transport pour une mutation au resultat ambigu', () => {
  for (const name of ['createRecords', 'updateRecords', 'deleteRecords']) {
    let restAttempts = 0;
    if (shouldFallbackToRestAfterMcpError({
      name,
      mutationMayHaveBeenSent: true,
    })) {
      restAttempts += 1;
    }
    assert.equal(restAttempts, 0, `${name} ne doit pas etre rejouee`);
  }

  assert.equal(shouldFallbackToRestAfterMcpError({
    name: 'queryRecords',
    mutationMayHaveBeenSent: true,
  }), true);
  assert.equal(shouldFallbackToRestAfterMcpError({
    name: 'updateRecords',
    mutationMayHaveBeenSent: false,
  }), true);
});

const originalEnvironment = {
  NOCODB_API_URL: process.env.NOCODB_API_URL,
  NOCODB_API_TOKEN: process.env.NOCODB_API_TOKEN,
  NOCODB_FORCE_REST: process.env.NOCODB_FORCE_REST,
  NOCODB_BASE_ID: process.env.NOCODB_BASE_ID,
  NOCODB_REST_TIMEOUT_MS: process.env.NOCODB_REST_TIMEOUT_MS,
  NOCODB_MCP_URL: process.env.NOCODB_MCP_URL,
  NOCODB_MCP_TOKEN: process.env.NOCODB_MCP_TOKEN,
  VERCEL: process.env.VERCEL,
};

process.env.NOCODB_API_URL = 'https://nocodb.invalid';
process.env.NOCODB_API_TOKEN = 'synthetic-token';
process.env.NOCODB_FORCE_REST = '1';
process.env.NOCODB_BASE_ID = 'synthetic-base';
process.env.NOCODB_REST_TIMEOUT_MS = '1000';

const { callNocoTool } = await import('./nocodbMcpClient.mjs?deadline-tests');

process.env.NOCODB_FORCE_REST = '0';
process.env.VERCEL = '';
process.env.NOCODB_MCP_URL = 'https://nocodb.invalid/mcp/synthetic';
process.env.NOCODB_MCP_TOKEN = 'synthetic-mcp-token';
const mcpTransport = await import('./nocodbMcpClient.mjs?fallback-integration-tests');

function mockMcpTransport(t, { connectError, callError } = {}) {
  const attempts = { connect: 0, mcp: 0, rest: 0 };
  t.mock.method(StdioClientTransport.prototype, 'start', async () => {
    assert.fail('Tests must never start a child process');
  });
  t.mock.method(StdioClientTransport.prototype, 'close', async () => {});
  t.mock.method(Client.prototype, 'connect', async () => {
    attempts.connect += 1;
    if (connectError) throw connectError;
  });
  t.mock.method(Client.prototype, 'callTool', async () => {
    attempts.mcp += 1;
    if (callError) throw callError;
    return { content: [{ type: 'text', text: '{"ok":true}' }] };
  });
  t.mock.method(globalThis, 'fetch', async () => {
    attempts.rest += 1;
    return { status: 200, text: async () => '{"Id":1,"name":"synthetic"}' };
  });
  t.mock.method(console, 'warn', () => {});
  t.after(() => mcpTransport.closeMcpClient());
  return attempts;
}

for (const name of ['createRecords', 'updateRecords', 'deleteRecords']) {
  test(`transport MCP : ${name} deja envoyee ne bascule jamais vers REST`, async (t) => {
    for (const message of ['request timeout', 'socket hang up', 'ECONNRESET', 'unknown failure']) {
      await t.test(message, async (t) => {
        const failure = new Error(message);
        const attempts = mockMcpTransport(t, { callError: failure });
        await assert.rejects(mcpTransport.callNocoTool(name, {
          tableId: 'synthetic', records: [{ fields: { name: 'synthetic' } }],
        }), (error) => error === failure);
        assert.deepEqual(attempts, { connect: 1, mcp: 1, rest: 0 });
      });
    }
  });
}

test('transport MCP : echec de connexion avant envoi autorise une seule ecriture REST', async (t) => {
  const attempts = mockMcpTransport(t, { connectError: new Error('connection timed out') });
  const records = await mcpTransport.callNocoTool('createRecords', {
    tableId: 'synthetic', records: [{ fields: { name: 'synthetic' } }],
  });
  assert.equal(records[0].id, '1');
  assert.deepEqual(attempts, { connect: 1, mcp: 0, rest: 1 });
});

test('transport MCP : une lecture en erreur conserve le repli REST', async (t) => {
  const attempts = mockMcpTransport(t, { callError: new Error('request timeout') });
  await mcpTransport.callNocoTool('getBaseInfo');
  assert.deepEqual(attempts, { connect: 1, mcp: 1, rest: 1 });
});

test('transport MCP : succes sans appel REST', async (t) => {
  const attempts = mockMcpTransport(t);
  assert.deepEqual(await mcpTransport.callNocoTool('createRecords', {}), { ok: true });
  assert.deepEqual(attempts, { connect: 1, mcp: 1, rest: 0 });
});

test('protected tables reject unguarded writes before either transport is used', async (t) => {
  const attempts = mockMcpTransport(t);
  mcpTransport.configureConditionalSyncTables(['protected_table']);
  t.after(() => mcpTransport.configureConditionalSyncTables([]));
  for (const name of ['updateRecords', 'createRecords']) {
    await assert.rejects(mcpTransport.callNocoTool(name, {
      tableId: 'protected_table', records: [{ id: '1', fields: { name: 'synthetic' } }],
    }), error => error.status === 428);
  }
  await assert.rejects(mcpTransport.callNocoTool('updateRecords', {
    tableId: 'protected_table', records: [{ id: '1', fields: {
      app_sync_revision: '12345678-1234-4234-8234-123456789012', name: 'synthetic',
    } }],
  }), error => error.status === 428);
  assert.deepEqual(attempts, { connect: 0, mcp: 0, rest: 0 });
});

test('unprotected tables retain their existing transport behavior', async (t) => {
  const attempts = mockMcpTransport(t);
  mcpTransport.configureConditionalSyncTables(['protected_table']);
  t.after(() => mcpTransport.configureConditionalSyncTables([]));
  await mcpTransport.callNocoTool('updateRecords', { tableId: 'other_table', records: [] });
  assert.deepEqual(attempts, { connect: 1, mcp: 1, rest: 0 });
});

test.after(() => {
  for (const [name, value] of Object.entries(originalEnvironment)) {
    if (value === undefined) {
      delete process.env[name];
    } else {
      process.env[name] = value;
    }
  }
});

test('transport REST : une erreur HTTP conserve statut et payload', async (t) => {
  const originalFetch = globalThis.fetch;
  let fetchCount = 0;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async () => {
    fetchCount += 1;
    return {
      status: 422,
      async text() {
        return '{"message":"invalid synthetic row","details":{"field":"name"}}';
      },
    };
  };

  await assert.rejects(
    callNocoTool('getBaseInfo'),
    (error) => {
      assert.equal(error.status, 422);
      assert.deepEqual(error.payload, {
        message: 'invalid synthetic row',
        details: { field: 'name' },
      });
      return true;
    },
  );
  assert.equal(fetchCount, 1);
});

test('transport REST : une erreur reseau ne devient pas une liste vide', async (t) => {
  const originalFetch = globalThis.fetch;
  const networkError = new Error('synthetic network failure');
  let fetchCount = 0;
  t.after(() => {
    globalThis.fetch = originalFetch;
  });
  globalThis.fetch = async () => {
    fetchCount += 1;
    throw networkError;
  };

  await assert.rejects(
    callNocoTool('queryRecords', { tableId: 'table-1' }),
    (error) => error === networkError,
  );
  assert.equal(fetchCount, 1);
});
