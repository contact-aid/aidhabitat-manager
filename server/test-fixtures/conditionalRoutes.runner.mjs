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
const mock = createRestMock({ referenceRows: {
  portails: [
    { Id: 1, libelle: 'Manuel' },
    { Id: 2, libelle: 'Électrique' },
    { Id: 3, libelle: 'Pas de portail' },
    { Id: 4, libelle: 'Aucun' },
  ],
} });
const nativeFetch = globalThis.fetch;
let apiOrigin;
const airtableCalls = [];
globalThis.fetch = (input, init = {}) => {
  const url = new URL(input instanceof Request ? input.url : input);
  if (apiOrigin && url.origin === apiOrigin) {
    return nativeFetch(input, { ...init, redirect: 'error' });
  }
  if (url.origin === 'https://api.airtable.com') {
    airtableCalls.push({ url, init });
    assert.equal(init.method, 'GET');
    assert.equal(init.headers?.Authorization, 'Bearer synthetic-airtable-read-only-token');
    if (url.pathname.endsWith('/tbl7qYd2ZKgwQVNU1')) {
      return Promise.resolve(Response.json({ records: [
        { id: 'recAAAAAAAAAAAAAA', fields: {
          'Dossier ID': 'FICTIF-1', 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Test'], 'Nom intervenant': ['Test Owner'],
          'No Client': ['recCCCCCCCCCCCCCC'], Commentaires: 'Note fictive',
        } },
        { id: 'recBBBBBBBBBBBBBB', fields: {
          'Dossier ID': 'AUTRE-2', 'Adaptation ou énergie': ['Adaptation'],
          'Intervenant couleur': ['Test'], 'Nom intervenant': ['Test Other'],
          'No Client': [],
        } },
      ] }));
    }
    return Promise.resolve(Response.json({ records: [
      { id: 'recCCCCCCCCCCCCCC', fields: {
        'Prénom': 'Camille', Nom: 'Fictif', 'Nb du foyer': 2,
      } },
    ] }));
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

  if (entity === 'dossier') {
    await check('read-only Airtable route scopes Adaptation to the authenticated intervenant', async () => {
      airtableCalls.length = 0;
      mock.row('dossier').uuid_source = 'airtable:recAAAAAAAAAAAAAA';
      expectStatus(await request('/api/airtable/adaptation-dossiers'), 401);
      const response = expectStatus(await request('/api/airtable/adaptation-dossiers', {
        token: clientA,
      }), 200);
      assert.equal(response.data.records.length, 1);
      assert.equal(response.data.records[0].airtableRecordId, 'recAAAAAAAAAAAAAA');
      assert.equal(response.data.records[0].nocodbDossierId, 'airtable:recAAAAAAAAAAAAAA');
      assert.equal(response.data.records[0].beneficiary.nombre_personnes, 2);
      assert(airtableCalls.length === 2);
      assert(airtableCalls.every((call) => call.init.method === 'GET'));
      assert.equal(mock.patches().length, 0);
    });
  }

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

  if (entity === 'beneficiaire') {
    await check('Flutter Concubinage maps to the En concubinage reference', async () => {
      mock.row(entity).situation_proprietaire_id1 = 601;
      const body = mutation(
        { familySituation: 'Concubinage' },
        { familySituation: 'Célibataire' },
      );
      expectStatus(await patch(clientA, body), 200);
      assertGuard(mock.patches()[0], revision, body.concurrency.writeId, {
        situation_proprietaire_id1: 602,
      });
      assert.equal(mock.row(entity).situation_proprietaire_id1, 602);
    });

    await check('absence labels and nullable booleans are canonical baselines', async () => {
      const body = mutation(
        { dependenceTxt: 'Canne', homeHelp: true },
        { dependenceTxt: 'Aucune', homeHelp: null },
      );
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.patches().length, 1);
      assertGuard(mock.patches()[0], revision, body.concurrency.writeId, {
        aide_a_domicile: true,
        dependance_particuliere_txt: 'Canne',
        dependances_particulieres_id: 901,
      });
    });
  }

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

  await check('two clients editing same field: guarded success, replay, then local priority', async () => {
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
    const second = mutation({ [definition.key]: definition.second }, {
      [definition.key]: baselineB[definition.key],
    });
    expectStatus(await patch(clientB, second), 200);
    assert.equal(mock.patches().length, 2);
    assertGuard(mock.patches()[1], body.concurrency.writeId,
      second.concurrency.writeId, { [definition.dbKey]: definition.second });
    assert.equal((await read(clientB))[definition.key], definition.second);
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
      expectStatus(retry, 200);
      assert.equal(mock.patches().length, 3);
      assert.equal(mock.patches()[2].body.app_sync_revision, bodies[loser].concurrency.writeId);
      const final = await read(clientA);
      if (independent) {
        assert.equal(final[definition.key], definition.first);
        assert.equal(final[definition.other], definition.independent);
      } else {
        assert.equal(final[definition.key], bodies[loser][definition.key]);
      }
    });
  }

  if (entity === 'dossier') {
    await check('legacy null beneficiaryPrepared compares as the GET false baseline', async () => {
      mock.row(entity).beneficiaire_prepare = null;
      const baseline = await read(clientA);
      assert.equal(baseline.beneficiaryPrepared, false);
      const body = mutation({ beneficiaryPrepared: true }, { beneficiaryPrepared: false });
      expectStatus(await patch(clientA, body), 200);
      assertGuard(mock.patches()[0], revision, body.concurrency.writeId, { beneficiaire_prepare: true });
    });

    await check('Checkbox metadata compares stored string false with boolean baseline', async () => {
      mock.row(entity).beneficiaire_prepare = 'false';
      const body = mutation({ beneficiaryPrepared: true }, { beneficiaryPrepared: false });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.patches().length, 1);
      assertGuard(mock.patches()[0], revision, body.concurrency.writeId, { beneficiaire_prepare: true });
      assert.equal((await read(clientB)).beneficiaryPrepared, true);
    });
  }

  if (entity === 'beneficiaire') {
    await check('synthetic APA edit survives sync, reload, and another edit', async () => {
      const baseline = await read(clientA);
      mock.row(entity).beneficiaire_apa = true;
      mock.row(entity).app_sync_revision = randomUUID();
      expectStatus(await patch(clientA, mutation({ apa: false }, { apa: baseline.apa })), 200);
      assert.equal(mock.row(entity).beneficiaire_apa, false);
      const reloaded = await read(clientB);
      assert.equal(reloaded.apa, false);
      expectStatus(await patch(clientB, mutation({ apa: true }, { apa: reloaded.apa })), 200);
      assert.equal((await read(clientA)).apa, true);
      assert.equal(mock.patches().length, 2);
    });

    await check('legacy scalar occupants accept a birth date and persist scalar plus JSON', async () => {
      const baseline = await read(clientA);
      assert.equal(mock.row(entity).occupants_json, null);
      assert.equal(baseline.occupants.length, 1);
      const occupants = structuredClone(baseline.occupants);
      occupants[0].birthDate = '1948-04-12';
      const body = mutation({ occupant1BirthDate: '1948-04-12', occupants }, {
        occupant1BirthDate: baseline.occupant1BirthDate,
        occupants: baseline.occupants,
      });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.row(entity).date_naissance_monsieur, '1948-04-12');
      assert.equal(JSON.parse(mock.row(entity).occupants_json)[0].birthDate, '1948-04-12');
      assert.equal((await read(clientB)).occupants[0].birthDate, '1948-04-12');
    });

    await check('a real concurrent occupants change yields to the local occupant edit', async () => {
      const baseline = await read(clientA);
      mock.row(entity).occupants_json = JSON.stringify([{ ...baseline.occupants[0], birthDate: '1930-01-01' }]);
      mock.row(entity).app_sync_revision = randomUUID();
      const occupants = structuredClone(baseline.occupants);
      occupants[0].birthDate = '1948-04-12';
      expectStatus(await patch(clientA, mutation({
        occupant1BirthDate: '1948-04-12', occupants,
      }, { occupant1BirthDate: baseline.occupant1BirthDate, occupants: baseline.occupants })), 200);
      assert.equal(JSON.parse(mock.row(entity).occupants_json)[0].birthDate, '1948-04-12');
      assert.equal(mock.patches().length, 1);
    });

    await check('legacy null beneficiary checkbox accepts the exposed false baseline', async () => {
      const baseline = await read(clientA);
      assert.equal(baseline.homeHelp, false);
      const body = mutation({ homeHelp: true }, { homeHelp: false });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.row(entity).aide_a_domicile, true);
    });
  }

  if (entity === 'logement') {
    await check('a present portal without motorisation resolves the Aucun reference', async () => {
      const baseline = await read(clientA);
      assert.equal(baseline.motorisationPortail, '');
      const values = { veranda: true, terrasse: true, jardin: true, motorisationPortail: 'Aucun' };
      const baseValues = { veranda: false, terrasse: false, jardin: false, motorisationPortail: '' };
      expectStatus(await patch(clientA, mutation(values, baseValues)), 200);
      assert.equal(mock.patches().length, 1);
      assert.equal(mock.row(entity).veranda, true);
      assert.equal(mock.row(entity).terrasse, true);
      assert.equal(mock.row(entity).jardin, true);
      assert.equal(mock.row(entity).portail_id1, 4);
      const confirmed = await read(clientA);
      assert.equal(confirmed.motorisationPortail, 'Aucun');
      assert.equal(confirmed.portailId, '4');
    });

    await check('legacy null housing checkbox accepts the exposed false baseline', async () => {
      const baseline = await read(clientA);
      assert.equal(baseline.basement, false);
      const body = mutation({ basement: true }, { basement: false });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.row(entity).sous_sol, true);
    });

    await check('an absent housing type remains empty and can be explicitly selected', async () => {
      const baseline = await read(clientA);
      assert.equal(baseline.typology, '');
      const body = mutation({ typology: 'Appartement' }, { typology: '' });
      expectStatus(await patch(clientA, body), 200);
      assert.equal(mock.row(entity).type_de_logement_id, 802);
    });

    await check('an unknown relation label fails explicitly without a write', async () => {
      const result = await patch(clientA, mutation({ typology: 'Type historique inconnu' }, { typology: '' }));
      assert.equal(result.status, 422, JSON.stringify(result.body));
      assert.equal(result.body.error, 'SYNC_RELATION_UNRESOLVED');
      assert.equal(mock.patches().length, 0);
    });
  }

  assert.equal(failures.length, 0, `${failures.length} scenario(s) failed: ${failures.map(({ name }) => name).join('; ')}`);
  console.log(`CONDITIONAL_ROUTES_PASS ${entity}: ${passed} HTTP scenarios`);
} finally {
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  globalThis.fetch = nativeFetch;
}
