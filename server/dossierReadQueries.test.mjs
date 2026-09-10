import assert from 'node:assert/strict';
import test from 'node:test';
import { NocodbRestTimeoutError } from './nocodbRequestDeadline.mjs';

import {
  dossierIdWhere,
  latestDossierRecord,
  readAuthorizedDossierRecord,
} from './dossierReadQueries.mjs';

const makeRecord = ({ id, dossierId, updatedAt, updatedAtLegacy, value }) => ({
  id: String(id),
  fields: {
    dossier_id: dossierId,
    uuid_source: `row-${id}`,
    value,
    ...(updatedAt ? { UpdatedAt: updatedAt } : {}),
    ...(updatedAtLegacy ? { updated_at: updatedAtLegacy } : {}),
  },
});

const parseDossierWhere = (where) => {
  const match = /^\(dossier_id,eq,(.*)\)$/.exec(where || '');
  if (!match) throw new Error(`Filtre inattendu: ${where}`);
  return JSON.parse(match[1]);
};

const createNocoSimulator = (sourceRecords, { pageSize = 100 } = {}) => {
  const calls = [];
  const queryRecords = async (options) => {
    calls.push(structuredClone(options));
    const filtered = options.where
      ? sourceRecords.filter(
        (record) => String(record.fields.dossier_id) === String(parseDossierWhere(options.where)),
      )
      : sourceRecords;
    const start = (options.page - 1) * pageSize;
    const records = filtered.slice(start, start + pageSize).map((record) => ({
      id: record.id,
      fields: Object.fromEntries(
        Object.entries(record.fields).filter(([name]) => options.fields.includes(name)),
      ),
    }));
    return {
      records,
      next: start + pageSize < filtered.length,
    };
  };

  const queryAll = async (tableId, options = {}) => {
    const records = [];
    let page = 1;
    while (true) {
      const payload = await queryRecords({
        tableId,
        page,
        pageSize,
        ...options,
      });
      records.push(...payload.records);
      if (!payload.next || payload.records.length === 0) break;
      page += 1;
    }
    return records;
  };

  return { calls, queryAll };
};

const allowDossier = ({ queryAll, dossierId = 'dossier-cible', fields }) => (
  readAuthorizedDossierRecord({
    appUser: { role: 'ERGO', ergoLabel: 'Coralie' },
    requestedDossierId: dossierId,
    ensureDossierRecord: async () => ({
      id: '501',
      fields: { uuid_source: dossierId, ergo_id: 'Coralie' },
    }),
    canAccessDossierRecord: (user, dossier) => (
      user.ergoLabel === dossier.fields.ergo_id
    ),
    queryAll,
    tableId: 'table-cible',
    fields,
  })
);

test('les trois lectures utilisent le filtre dossier et leur projection', async (t) => {
  const cases = [
    {
      name: 'diagnostic sanitaires',
      fields: ['uuid_source', 'dossier_id', 'sdb_instances_json', 'updated_at', 'UpdatedAt'],
    },
    {
      name: 'mesures',
      fields: ['uuid_source', 'dossier_id', 'debout_hauteur_coude', 'updated_at', 'UpdatedAt'],
    },
    {
      name: 'observations',
      fields: ['uuid_source', 'dossier_id', 'observation_equipements', 'UpdatedAt'],
    },
  ];

  for (const entry of cases) {
    await t.test(entry.name, async () => {
      const simulator = createNocoSimulator([
        makeRecord({
          id: 1,
          dossierId: 'autre-dossier',
          updatedAt: '2026-09-09T11:00:00.000Z',
          value: 'hors dossier',
        }),
        makeRecord({
          id: 2,
          dossierId: 'dossier-cible',
          updatedAt: '2026-09-09T10:00:00.000Z',
          value: 'attendu',
        }),
      ]);

      const result = await allowDossier({
        queryAll: simulator.queryAll,
        fields: entry.fields,
      });

      assert.equal(result.accessAllowed, true);
      assert.equal(result.record.id, '2');
      assert.equal(result.record.fields.dossier_id, 'dossier-cible');
      assert.deepEqual(simulator.calls, [{
        tableId: 'table-cible',
        page: 1,
        pageSize: 100,
        fields: entry.fields,
        where: '(dossier_id,eq,"dossier-cible")',
      }]);
    });
  }
});

test('une ligne absente conserve le résultat null', async () => {
  const simulator = createNocoSimulator([
    makeRecord({ id: 1, dossierId: 'autre-dossier', value: 'hors dossier' }),
  ]);
  const result = await allowDossier({
    queryAll: simulator.queryAll,
    fields: ['uuid_source', 'dossier_id', 'UpdatedAt'],
  });

  assert.equal(result.record, null);
  assert.equal(simulator.calls.length, 1);
});

test('plusieurs lignes conservent la règle UpdatedAt, updated_at puis Id', async () => {
  const records = [
    makeRecord({
      id: 2,
      dossierId: 'dossier-cible',
      updatedAtLegacy: '2026-09-09T12:00:00.000Z',
      value: 'legacy plus récent',
    }),
    makeRecord({
      id: 8,
      dossierId: 'dossier-cible',
      updatedAt: '2026-09-09T13:00:00.000Z',
      value: 'plus récent',
    }),
    makeRecord({
      id: 9,
      dossierId: 'dossier-cible',
      updatedAt: '2026-09-09T13:00:00.000Z',
      value: 'égalité départagée par Id',
    }),
  ];

  assert.equal(latestDossierRecord(records, 'dossier-cible').id, '9');

  const simulator = createNocoSimulator(records);
  const result = await allowDossier({
    queryAll: simulator.queryAll,
    fields: ['uuid_source', 'dossier_id', 'value', 'updated_at', 'UpdatedAt'],
  });
  assert.equal(result.record.id, '9');
  assert.equal(result.record.fields.value, 'égalité départagée par Id');
});

test('la pagination reste complète pour plusieurs lignes du dossier', async () => {
  const records = Array.from({ length: 205 }, (_, index) => makeRecord({
    id: index + 1,
    dossierId: 'dossier-cible',
    updatedAt: new Date(Date.UTC(2026, 0, 1, 0, 0, index)).toISOString(),
    value: `page-${Math.floor(index / 100) + 1}`,
  }));
  const simulator = createNocoSimulator(records);
  const result = await allowDossier({
    queryAll: simulator.queryAll,
    fields: ['uuid_source', 'dossier_id', 'value', 'UpdatedAt'],
  });

  assert.equal(result.record.id, '205');
  assert.equal(result.record.fields.value, 'page-3');
  assert.deepEqual(simulator.calls.map((call) => call.page), [1, 2, 3]);
  assert.ok(simulator.calls.every(
    (call) => call.where === '(dossier_id,eq,"dossier-cible")',
  ));
});

test('un identifiant atypique est transmis sans perte et reste isolé', async () => {
  const dossierId = 'legacy dossier/42:À "tester"';
  const simulator = createNocoSimulator([
    makeRecord({ id: 1, dossierId: 'legacy dossier/42:À', value: 'préfixe' }),
    makeRecord({ id: 2, dossierId, value: 'exact' }),
  ]);
  const result = await allowDossier({
    queryAll: simulator.queryAll,
    dossierId,
    fields: ['uuid_source', 'dossier_id', 'value', 'UpdatedAt'],
  });

  assert.equal(dossierIdWhere(dossierId), '(dossier_id,eq,"legacy dossier/42:À \\"tester\\"")');
  assert.equal(result.record.id, '2');
  assert.equal(result.record.fields.value, 'exact');
  assert.equal(parseDossierWhere(simulator.calls[0].where), dossierId);
});

test('la résolution utilise l’UUID canonique plutôt que l’alias demandé', async () => {
  const simulator = createNocoSimulator([
    makeRecord({ id: 1, dossierId: 'temp-beneficiaire-42', value: 'alias obsolète' }),
    makeRecord({ id: 2, dossierId: 'uuid-canonique-42', value: 'canonique' }),
  ]);
  const result = await readAuthorizedDossierRecord({
    appUser: { role: 'ADMIN' },
    requestedDossierId: 'temp-beneficiaire-42',
    ensureDossierRecord: async () => ({
      id: '501',
      fields: { uuid_source: 'uuid-canonique-42', ergo_id: 'Coralie' },
    }),
    canAccessDossierRecord: () => true,
    queryAll: simulator.queryAll,
    tableId: 'table-cible',
    fields: ['uuid_source', 'dossier_id', 'value', 'UpdatedAt'],
  });

  assert.equal(result.record.id, '2');
  assert.equal(result.record.fields.value, 'canonique');
  assert.equal(simulator.calls[0].where, '(dossier_id,eq,"uuid-canonique-42")');
});

test('la vérification locale écarte une ligne hors dossier renvoyée à tort', async () => {
  const result = await allowDossier({
    fields: ['uuid_source', 'dossier_id', 'value', 'UpdatedAt'],
    queryAll: async () => [
      makeRecord({
        id: 99,
        dossierId: 'autre-dossier',
        updatedAt: '2026-09-09T15:00:00.000Z',
        value: 'hors dossier plus récent',
      }),
      makeRecord({
        id: 2,
        dossierId: 'dossier-cible',
        updatedAt: '2026-09-09T10:00:00.000Z',
        value: 'attendu',
      }),
    ],
  });

  assert.equal(result.record.id, '2');
  assert.equal(result.record.fields.value, 'attendu');
});

test('un refus d’accès intervient avant toute lecture de la table métier', async () => {
  let ensureCalls = 0;
  let queryCalls = 0;
  const result = await readAuthorizedDossierRecord({
    appUser: { role: 'ERGO', ergoLabel: 'Christelle' },
    requestedDossierId: 'dossier-cible',
    ensureDossierRecord: async () => {
      ensureCalls += 1;
      return {
        id: '501',
        fields: { uuid_source: 'dossier-cible', ergo_id: 'Coralie' },
      };
    },
    canAccessDossierRecord: (user, dossier) => (
      user.ergoLabel === dossier.fields.ergo_id
    ),
    queryAll: async () => {
      queryCalls += 1;
      return [];
    },
    tableId: 'table-cible',
    fields: ['uuid_source', 'dossier_id'],
  });

  assert.equal(result.accessAllowed, false);
  assert.equal(result.record, null);
  assert.equal(ensureCalls, 1);
  assert.equal(queryCalls, 0);
});

test('le filtre réduit les appels simulés sans changer le résultat', async () => {
  const target = makeRecord({
    id: 251,
    dossierId: 'dossier-cible',
    updatedAt: '2026-09-09T14:00:00.000Z',
    value: 'attendu',
  });
  const records = [
    ...Array.from({ length: 250 }, (_, index) => makeRecord({
      id: index + 1,
      dossierId: `autre-${index}`,
      updatedAt: '2026-09-09T10:00:00.000Z',
      value: 'hors dossier',
    })),
    target,
  ];
  const fields = ['uuid_source', 'dossier_id', 'value', 'UpdatedAt'];

  const before = createNocoSimulator(records);
  const beforeRecords = await before.queryAll('table-cible', { fields });
  const beforeResult = latestDossierRecord(beforeRecords, 'dossier-cible');

  const after = createNocoSimulator(records);
  const afterResult = await allowDossier({ queryAll: after.queryAll, fields });

  assert.equal(beforeResult.id, afterResult.record.id);
  assert.equal(before.calls.length, 3);
  assert.equal(after.calls.length, 1);
  assert.equal(after.calls[0].where, '(dossier_id,eq,"dossier-cible")');
});

test('sans UUID canonique la lecture conserve l identifiant demande', async () => {
  const simulator = createNocoSimulator([
    makeRecord({ id: 2, dossierId: 'legacy-42', value: 'attendu' }),
  ]);
  const result = await readAuthorizedDossierRecord({
    appUser: { role: 'ADMIN' },
    requestedDossierId: 'legacy-42',
    ensureDossierRecord: async () => ({ id: '501', fields: {} }),
    canAccessDossierRecord: () => true,
    queryAll: simulator.queryAll,
    tableId: 'table-cible',
    fields: ['uuid_source', 'dossier_id', 'value'],
  });

  assert.equal(result.record.id, '2');
  assert.equal(simulator.calls[0].where, '(dossier_id,eq,"legacy-42")');
});

test('les priorites temporelles et le repli created_at restent inchanges', () => {
  const record = (id, dates) => ({
    id: String(id),
    fields: { dossier_id: 'dossier-cible', ...dates },
  });
  const date = (day) => `2026-09-${day}T12:00:00.000Z`;
  const records = [
    record(99, { UpdatedAt: date('01'), updated_at: date('09') }),
    record(98, { updated_at: date('02'), created_at: date('09') }),
    record(97, { created_at: date('03') }),
  ];
  assert.equal(latestDossierRecord(records, 'dossier-cible').id, '97');
  assert.equal(latestDossierRecord(records.slice(0, 2), 'dossier-cible').id, '98');
  assert.equal(
    latestDossierRecord([record(2, {}), record(10, {})], 'dossier-cible').id,
    '10',
  );
});

test('une erreur de resolution interdit toute lecture metier', async () => {
  const failure = new Error('synthetic resolution failure');
  await assert.rejects(readAuthorizedDossierRecord({
    appUser: { role: 'ADMIN' },
    requestedDossierId: 'dossier-cible',
    ensureDossierRecord: async () => { throw failure; },
    canAccessDossierRecord: () => assert.fail('authorization before resolution'),
    queryAll: async () => assert.fail('business query after resolution failure'),
    tableId: 'table-cible',
    fields: ['dossier_id'],
  }), (error) => error === failure);
});

test('une erreur ou deadline NocoDB ne devient pas une reponse vide', async () => {
  const failures = [
    new Error('synthetic query failure'),
    new NocodbRestTimeoutError({ method: 'GET', path: '/synthetic', timeoutMs: 1000 }),
  ];
  for (const failure of failures) {
    let queryCount = 0;
    await assert.rejects(allowDossier({
      fields: ['dossier_id'],
      queryAll: async () => {
        queryCount += 1;
        throw failure;
      },
    }), (error) => error === failure);
    assert.equal(queryCount, 1, 'pas de repli sur une lecture complete');
  }
});
