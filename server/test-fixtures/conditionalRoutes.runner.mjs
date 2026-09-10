import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { setImmediate } from 'node:timers/promises';
import { once } from 'node:events';
import {
  createRestMock, tables, revision, timestamp, password, ownerEmail, otherEmail,
  patientId, dossierId,
} from './conditionalRoutes.rest.mjs';

const entity = process.argv[2];
const definitions = {
  dossier: { route: `/api/dossiers/${dossierId}`, id: 101,
    key: 'compteAnah', dbKey: 'compte_anah', other: 'natureAccompagnement', dbOther: 'nature_accompagnement',
    first: 'client A', second: 'client B', independent: 'independent change', select: (dossier) => dossier },
  beneficiaire: { route: `/api/beneficiaires/${patientId}`, id: 201,
    key: 'phone', dbKey: 'telephone', other: 'email', dbOther: 'mail',
    first: '0100000001', second: '0100000002', independent: 'changed@patient.test.invalid', select: (dossier) => dossier.patient },
  logement: { route: `/api/logements/by-beneficiary/${patientId}`, id: 301,
    key: 'comments', dbKey: 'commentaire', other: 'accessObservation', dbOther: 'observation_accessibilite',
    first: 'client A', second: 'client B', independent: 'independent change', select: (dossier) => dossier.housing },
};
const definition = definitions[entity];
assert(definition, `Unknown test entity: ${entity}`);
const mock = createRestMock();
const nativeFetch = globalThis.fetch;
let apiOrigin;
globalThis.fetch = (input, init = {}) => {
  const url = new URL(input instanceof Request ? input.url : input);
  if (apiOrigin && url.origin === apiOrigin) {
    return nativeFetch(input, { ...init, redirect: 'error' });
  }
  // No URL except this process's exact Express origin ever reaches native fetch.
  return mock.fetch(input, init);
};

const { default: app } = await import('../index.mjs');
const server = app.listen(0, '127.0.0.1');
await once(server, 'listening');
apiOrigin = `http://127.0.0.1:${server.address().port}`;
const failures = [];
let passed = 0;
const request = async (pathname, { token, method = 'GET', body } = {}) => {
  const response = await fetch(apiOrigin + pathname, {
    method, headers: { 'content-type': 'application/json', ...(token ? { 'x-app-session': token } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(8000),
  });
  return { status: response.status, body: await response.json() };
};
const expectStatus = (result, status) => {
  assert.equal(result.status, status, JSON.stringify(result.body));
  return result.body;
};
const login = async (email) => {
  const body = expectStatus(await request('/api/auth/login', { method: 'POST', body: { email, password } }), 200);
  assert.equal(body.data.user.email, email);
  assert.equal(body.data.user.role, 'ERGO');
  assert.match(body.data.token, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  const session = expectStatus(await request('/api/auth/session', { token: body.data.token }), 200);
  assert.equal(session.data.user.email, email);
  return body.data.token;
};
const patch = (token, body) => request(definition.route, { method: 'PATCH', token, body });
const mutation = (values, baseValues, writeId = randomUUID()) => ({
  ...values, concurrency: { version: 1, writeId, baseValues },
});
const read = async (token) => {
  const dossiers = expectStatus(await request('/api/dossiers', { token }), 200);
  const dossier = dossiers.find((item) => item.id === dossierId);
  assert(dossier, 'Real GET /api/dossiers must return the fixture');
  return definition.select(dossier);
};
const check = async (name, run) => {
  mock.reset();
  try {
    await run();
    assert.deepEqual(mock.violations, [], 'Fail-closed REST mock recorded an unexpected call, even if the app swallowed it');
    passed++;
    console.log(`PASS ${entity}: ${name}`);
  } catch (error) {
    failures.push({ name, error });
    console.error(`FAIL ${entity}: ${name}\n${error.stack}\nREST violations: ${JSON.stringify(mock.violations)}`);
  }
};
const assertGuard = (call, expectedRevision, writeId, fields) => {
  assert.equal(call.method, 'PATCH');
  assert.equal(call.path, `/api/v1/db/data/bulk/noco/conditional_http_base/${tables[entity]}/all`);
  assert.equal(call.query.where, `(Id,eq,${definition.id})~and(app_sync_revision,eq,${expectedRevision})`);
  assert.deepEqual(call.body, { ...fields, app_sync_revision: writeId });
};

try {
  // Warmup uses in-memory credentials and immediately resolved mock REST calls.
  // Drain its microtasks before making the first actual login request.
  await setImmediate();
  const clientA = await login(ownerEmail);
  const clientB = await login(ownerEmail);
  const otherErgo = await login(otherEmail);
  assert.deepEqual(mock.violations, [], 'Startup and real logins must use only known REST calls');

  await check('wrong password rejected by real login', async () => {
    expectStatus(await request('/api/auth/login', {
      method: 'POST', body: { email: ownerEmail, password: 'wrong-synthetic-password' },
    }), 401);
  });

  await check('unauthenticated and forged sessions return 401 without PATCH', async () => {
    const body = mutation({ [definition.key]: definition.first }, { [definition.key]: 'initial' });
    for (const token of [undefined, 'invalid.signature', `local-auth:${Buffer.from(ownerEmail).toString('base64')}`]) {
      expectStatus(await patch(token, body), 401);
    }
    assert.equal(mock.patches().length, 0);
  });

  await check('other authenticated ergo returns 403 without PATCH', async () => {
    const before = structuredClone(mock.row(entity));
    expectStatus(await patch(otherErgo, mutation({ [definition.key]: definition.first }, {
      [definition.key]: before[definition.dbKey],
    })), 403);
    assert.equal(mock.patches().length, 0);
    assert.deepEqual(mock.row(entity), before);
  });

  await check('missing guard or writeId returns 428 without PATCH', async () => {
    const body = { [definition.key]: definition.first };
    expectStatus(await patch(clientA, body), 428);
    expectStatus(await patch(clientA, { ...body, concurrency: { version: 1, baseValues: {} } }), 428);
    assert.equal(mock.patches().length, 0);
  });

  await check('unprepared record revision returns 503 without PATCH', async () => {
    delete mock.row(entity).app_sync_revision;
    const result = await patch(clientA, mutation({ [definition.key]: definition.first }, {
      [definition.key]: mock.row(entity)[definition.dbKey],
    }));
    assert.equal(expectStatus(result, 503).error, 'SYNC_REVISION_NOT_PREPARED');
    assert.equal(mock.patches().length, 0);
  });

  await check('invalid revision-column metadata returns 503 without PATCH', async () => {
    const column = mock.schemas[tables[entity]].find((entry) => entry.title === 'app_sync_revision');
    const originalType = column.uidt;
    try {
      column.uidt = 'Number';
      expectStatus(await patch(clientA, mutation({ [definition.key]: definition.first }, {
        [definition.key]: mock.row(entity)[definition.dbKey],
      })), 503);
      assert.equal(mock.patches().length, 0);
      assert.equal(mock.row(entity).app_sync_revision, revision);
    } finally {
      column.uidt = originalType;
    }
  });

  await check('two clients editing same field: guarded success, replay, then 409', async () => {
    const baselineA = await read(clientA);
    const baselineB = await read(clientB);
    assert.equal(baselineA[definition.key], baselineB[definition.key]);
    assert.equal(baselineA.updatedAt, timestamp);
    const body = mutation({ [definition.key]: definition.first }, { [definition.key]: baselineA[definition.key] });
    const ok = expectStatus(await patch(clientA, body), 200);
    assert.equal(ok.success, true);
    assert.equal(ok.data.updatedAt, mock.row(entity).UpdatedAt);
    assert.equal(mock.patches().length, 1);
    assertGuard(mock.patches()[0], revision, body.concurrency.writeId, { [definition.dbKey]: definition.first });
    assert.equal(mock.row(entity).app_sync_revision, body.concurrency.writeId);
    assert(mock.calls.some((call) => call.path === `/api/v2/meta/tables/${tables[entity]}`));
    expectStatus(await patch(clientA, body), 200);
    assert.equal(mock.patches().length, 1, 'Exact replay must not send another PATCH');
    const conflict = expectStatus(await patch(clientB, mutation({ [definition.key]: definition.second }, {
      [definition.key]: baselineB[definition.key],
    })), 409);
    assert.equal(conflict.error, 'SYNC_FIELD_CONFLICT');
    assert.equal(conflict.conflict, true);
    assert.equal(conflict.remoteData[definition.dbKey], definition.first);
    assert.equal(conflict.remoteData.app_sync_revision, body.concurrency.writeId);
    assert.equal(mock.patches().length, 1);
    assert.equal((await read(clientB))[definition.key], definition.first);
  });

  await check('two clients editing independent fields preserve both changes', async () => {
    const a = await read(clientA);
    const b = await read(clientB);
    const first = mutation({ [definition.key]: definition.first }, { [definition.key]: a[definition.key] });
    const second = mutation({ [definition.other]: definition.independent }, { [definition.other]: b[definition.other] });
    expectStatus(await patch(clientA, first), 200);
    expectStatus(await patch(clientB, second), 200);
    assert.equal(mock.patches().length, 2);
    assertGuard(mock.patches()[1], first.concurrency.writeId, second.concurrency.writeId, {
      [definition.dbOther]: definition.independent,
    });
    const current = await read(clientA);
    assert.equal(current[definition.key], definition.first);
    assert.equal(current[definition.other], definition.independent);
  });

  await check('lost response returns 503, stable writeId replay confirms without PATCH', async () => {
    const initial = await read(clientA);
    const body = mutation({ [definition.key]: definition.first }, { [definition.key]: initial[definition.key] });
    mock.loseNextResponse();
    assert.equal(expectStatus(await patch(clientA, body), 503).error, 'SYNC_WRITE_UNCONFIRMED');
    assert.equal(mock.row(entity).app_sync_revision, body.concurrency.writeId);
    assert.equal(mock.patches().length, 1);
    expectStatus(await patch(clientA, body), 200);
    assert.equal(mock.patches().length, 1);
    const misuse = structuredClone(body);
    misuse[definition.key] = definition.second;
    assert.equal(expectStatus(await patch(clientA, misuse), 409).error, 'SYNC_WRITE_ID_MISMATCH');
    assert.equal(mock.patches().length, 1);
  });

  for (const independent of [false, true]) {
    await check(`simultaneous clients (${independent ? 'independent fields' : 'same field'}) use atomic guards`, async () => {
      const a = await read(clientA);
      const b = await read(clientB);
      const secondKey = independent ? definition.other : definition.key;
      const secondValue = independent ? definition.independent : definition.second;
      const bodies = [
        mutation({ [definition.key]: definition.first }, { [definition.key]: a[definition.key] }),
        mutation({ [secondKey]: secondValue }, { [secondKey]: b[secondKey] }),
      ];
      mock.raceNextTwoPatches();
      const outcomes = await Promise.all([patch(clientA, bodies[0]), patch(clientB, bodies[1])]);
      assert.deepEqual(outcomes.map((result) => result.status).sort(), [200, 503]);
      assert.equal(mock.patches().length, 2);
      assert.equal(mock.patches().filter((call) => call.matched === 1).length, 1);
      assert.equal(mock.patches().filter((call) => call.matched === 0).length, 1);
      for (const call of mock.patches()) {
        assert.equal(call.query.where, `(Id,eq,${definition.id})~and(app_sync_revision,eq,${revision})`);
      }
      const loser = outcomes.findIndex((result) => result.status === 503);
      const retry = await patch(loser === 0 ? clientA : clientB, bodies[loser]);
      expectStatus(retry, independent ? 200 : 409);
      assert.equal(mock.patches().length, independent ? 3 : 2);
      if (independent) {
        assert.equal(mock.patches()[2].body.app_sync_revision, bodies[loser].concurrency.writeId);
        const final = await read(clientA);
        assert.equal(final[definition.key], definition.first);
        assert.equal(final[definition.other], definition.independent);
      } else {
        assert.equal(retry.body.error, 'SYNC_FIELD_CONFLICT');
      }
    });
  }

  if (entity === 'dossier') {
    await check('Checkbox metadata compares stored string false with boolean baseline', async () => {
      mock.row(entity).beneficiaire_prepare = 'false';
      const body = mutation({ beneficiaryPrepared: true }, { beneficiaryPrepared: false });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.patches().length, 1);
      assertGuard(mock.patches()[0], revision, body.concurrency.writeId, { beneficiaire_prepare: true });
      assert.equal((await read(clientB)).beneficiaryPrepared, true);
    });
  }

  assert.equal(failures.length, 0, `${failures.length} scenario(s) failed: ${failures.map(({ name }) => name).join('; ')}`);
  console.log(`CONDITIONAL_ROUTES_PASS ${entity}: ${passed} HTTP scenarios`);
} finally {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  globalThis.fetch = nativeFetch;
}
