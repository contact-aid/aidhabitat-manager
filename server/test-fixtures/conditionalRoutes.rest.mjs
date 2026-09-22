import assert from 'node:assert/strict';
import { buildPasswordCredential } from '../passwordCredential.mjs';

export const origin = 'https://nocodb.test.invalid';
export const baseId = 'conditional_http_base';
export const revision = '11111111-1111-4111-8111-111111111111';
export const timestamp = '2026-09-01T10:00:00.000Z';
export const password = 'Synthetic-HTTP-password-only!';
export const ownerEmail = 'owner@conditional.test.invalid';
export const otherEmail = 'other@conditional.test.invalid';
export const patientId = 'nocodb-beneficiaire-201';
export const dossierId = '22222222-2222-4222-8222-222222222222';

// IDs and field names mirror index.mjs TABLES/FIELD_SETS and its domain mappers.
// Schemas describe this synthetic REST database; they are not a production schema claim.
export const tables = {
  dossier: 'mez74y7ndoej30p', beneficiaire: 'muvp56d5i9z2qbe', logement: 'mgdpvdrnzyy6n4k',
  ergos: 'mww8mr4ngp3nbxh', context: 'mjyj2lz4wfs5pd5', admin: 'mv2hgaqj3u5ittg',
  communes: 'mtwhx481kcfn19h', situations: 'mqwqqzsfopejd5q', statuts: 'mqgrx6hut8oskbr',
  dependances: 'm09p3a4xns7wqdg', caisses: 'mxmsm320nnljdmm', caissesComp: 'm067j5k5a03beog',
  baremes: 'mtg6pgm9t274ya9', types: 'mp34j2fxnupoxd0', garages: 'my9em2miybwiwr0',
  portails: 'm8e1g1ab3a4ubtx',
  mobile_documents: 'test_mobile_documents', mobile_document_chunks: 'test_mobile_chunks',
  mobile_note_pages: 'test_mobile_notes', mobile_visit_recommendations: 'test_mobile_recommendations',
};

const columns = (types) => [
  { title: 'Id', uidt: 'ID', pk: true },
  { title: 'app_sync_revision', uidt: 'SingleLineText', pk: false },
  ...Object.entries(types).map(([title, uidt]) => ({ title, uidt, pk: false })),
];

export function createRestMock({ referenceRows = {} } = {}) {
  const credential = buildPasswordCredential(password).serialized;
  const members = [
    [1, 'contact@aidhabitat.fr', 'Renan'],
    [2, 'c.demenais@aidhabitat.fr', 'Coralie'],
    [3, 'c.jeuland@aidhabitat.fr', 'Christelle'],
    [4, ownerEmail, 'Test Owner'], [5, otherEmail, 'Test Other'],
  ].map(([Id, email, prenom]) => ({ Id, email, prenom, nom: '',
    uuid_source: `synthetic-member-${Id}`, etablissements_id: 2, mot_de_passe: credential }));
  const initial = Object.fromEntries(Object.values(tables).map((id) => [id, []]));
  initial[tables.ergos] = members;
  for (const [entity, records] of Object.entries(referenceRows)) initial[tables[entity]] = structuredClone(records);
  initial[tables.dossier] = [{ Id: 101, uuid_source: dossierId, patient_id: patientId,
    beneficiaires_id: 201, ergo_id: 'Test Owner', status: 'A visiter',
    compte_anah: 'initial', nature_accompagnement: 'initial', beneficiaire_prepare: false,
    visit_date: null, app_sync_revision: revision, UpdatedAt: timestamp }];
  initial[tables.beneficiaire] = [{ Id: 201, prenom: 'Synthetic', nom: 'Patient',
    telephone: '0100000000', mail: 'initial@patient.test.invalid',
    app_sync_revision: revision, CreatedAt: timestamp, UpdatedAt: timestamp }];
  initial[tables.logement] = [{ Id: 301, uuid_source: 'synthetic-housing',
    beneficiaire_id: patientId, beneficiaires_id: 201, commentaire: 'initial',
    observation_accessibilite: 'initial', app_sync_revision: revision, UpdatedAt: timestamp }];
  const schemas = {
    [tables.dossier]: columns({ compte_anah: 'SingleLineText', nature_accompagnement: 'SingleLineText',
      beneficiaire_prepare: 'Checkbox', visit_date: 'Date', status: 'SingleLineText' }),
    [tables.beneficiaire]: columns({ telephone: 'PhoneNumber', mail: 'Email' }),
    [tables.logement]: columns({ commentaire: 'LongText', observation_accessibilite: 'LongText' }),
    [tables.mobile_note_pages]: columns(Object.fromEntries([
      'uuid_source', 'beneficiaire_id', 'dossier_id', 'beneficiaire_prenom', 'beneficiaire_nom',
      'beneficiaire_nom_complet', 'dossier_libelle', 'scope_type', 'scope_id', 'tab_key',
      'sub_tab_key', 'page_number', 'text_content', 'drawing_json', 'layout_kind', 'updated_at',
    ].map((name) => [name, 'SingleLineText']))),
  };
  let rows = structuredClone(initial);
  const calls = [];
  const violations = [];
  let race = null;
  let loseNextResponse = false;
  const businessIds = [tables.dossier, tables.beneficiaire, tables.logement];
  const json = (payload) => new Response(JSON.stringify(payload), {
    status: 200, headers: { 'content-type': 'application/json' },
  });
  const paramsOnly = (url, allowed) => {
    for (const key of url.searchParams.keys()) {
      assert(allowed.includes(key), `Unknown query parameter: ${key}`);
      assert.equal(url.searchParams.getAll(key).length, 1, `Repeated parameter: ${key}`);
    }
  };
  const matches = (where, row) => {
    if (!where) return true;
    const parts = where.split('~and');
    return parts.map((part) => {
      const match = /^\((Id|uuid_source|patient_id|beneficiaires_id|beneficiaire_id|app_sync_revision),eq,([^(),]+)\)$/.exec(part);
      assert(match, `Unsupported where: ${where}`);
      return String(row[match[1]]) === match[2];
    }).every(Boolean);
  };

  return {
    calls, violations, schemas,
    row: (entity) => rows[tables[entity]][0],
    rows: (entity) => rows[tables[entity]],
    removeHousing() { rows[tables.logement] = []; },
    patches: () => calls.filter((call) => call.method === 'PATCH'),
    reset() { rows = structuredClone(initial); calls.length = 0; race = null; loseNextResponse = false; },
    loseNextResponse() { loseNextResponse = true; },
    raceNextTwoPatches() {
      let release;
      const ready = new Promise((resolve) => { release = resolve; });
      race = { ready, release, arrivals: 0 };
    },
    async fetch(input, init = {}) {
      const url = new URL(input instanceof Request ? input.url : input);
      const method = init.method || 'GET';
      const call = { method, path: url.pathname, query: Object.fromEntries(url.searchParams) };
      calls.push(call);
      try {
        assert.equal(url.origin, origin, 'External connections forbidden');
        assert.equal(new Headers(init.headers).get('xc-token'), 'synthetic-conditional-http-token');
        if (url.pathname === `/api/v2/meta/bases/${baseId}/tables` && method === 'GET') {
          paramsOnly(url, []);
          return json({ list: Object.entries(tables).map(([title, id]) => ({ title, id })) });
        }
        const meta = /^\/api\/v2\/meta\/tables\/([^/]+)$/.exec(url.pathname);
        if (meta && method === 'GET') {
          paramsOnly(url, []);
          assert(schemas[meta[1]], `Unknown schema: ${meta[1]}`);
          return json({ id: meta[1], base_id: baseId, columns: schemas[meta[1]] });
        }
        const records = /^\/api\/v2\/tables\/([^/]+)\/records$/.exec(url.pathname);
        if (records) {
          const tableId = records[1];
          assert(Object.hasOwn(rows, tableId), `Unknown table: ${tableId}`);
          if (method === 'GET') {
            paramsOnly(url, ['page', 'limit', 'offset', 'where', 'fields', 'sort']);
            const where = url.searchParams.get('where');
            // Validate even filters on empty tables.
            if (where) matches(where, {});
            let list = rows[tableId].filter((row) => matches(where, row));
            const sort = url.searchParams.get('sort');
            if (sort) {
              assert(['Id', '-Id', '-UpdatedAt', '-updated_at'].includes(sort), `Unknown sort: ${sort}`);
              const key = sort.replace(/^-/, '');
              list.sort((a, b) => String(a[key]).localeCompare(String(b[key])) * (sort.startsWith('-') ? -1 : 1));
            }
            const totalRows = list.length;
            const offset = Number(url.searchParams.get('offset') || 0);
            const limit = Number(url.searchParams.get('limit') || 25);
            assert(Number.isSafeInteger(offset) && offset >= 0);
            assert(Number.isSafeInteger(limit) && limit > 0);
            list = list.slice(offset, offset + limit);
            const fields = url.searchParams.get('fields')?.split(',');
            if (fields) list = list.map((row) => Object.fromEntries(fields.map((key) => [key, row[key] ?? null])));
            return json({ list, pageInfo: { totalRows, isLastPage: offset + limit >= totalRows } });
          }
          if (method === 'POST') {
            paramsOnly(url, []);
            call.body = JSON.parse(init.body);
            const inserts = Array.isArray(call.body) ? call.body : [call.body];
            const created = inserts.map((fields, index) => ({
              Id: Math.max(0, ...rows[tableId].map((row) => Number(row.Id) || 0)) + index + 1,
              ...fields,
              CreatedAt: '2026-09-02T10:00:00.000Z',
              UpdatedAt: '2026-09-02T10:00:00.000Z',
            }));
            rows[tableId].push(...created);
            if (loseNextResponse) {
              loseNextResponse = false;
              throw new Error('SIMULATED_RESPONSE_LOST_AFTER_COMMIT');
            }
            return json(Array.isArray(call.body) ? created : created[0]);
          }
          if (method === 'PATCH' && tableId === tables.ergos) {
            paramsOnly(url, []);
            call.body = JSON.parse(init.body);
            assert(Array.isArray(call.body));
            for (const patch of call.body) {
              assert([1, 2, 3].includes(patch.Id), 'Only preset-member startup synchronization is allowed');
              const member = rows[tableId].find((row) => row.Id === patch.Id);
              assert.deepEqual(patch, { Id: member.Id, prenom: member.Id === 1 ? "Aid'habitat" : member.prenom, nom: member.nom,
                email: member.email, ...(member.Id === 1 ? {} : { etablissements_id: 2 }) });
              Object.assign(member, patch);
            }
            return json(call.body);
          }
        }
        const bulk = new RegExp(`^/api/v1/db/data/bulk/noco/${baseId}/([^/]+)/all$`).exec(url.pathname);
        if (bulk && method === 'PATCH') {
          const tableId = bulk[1];
          assert(businessIds.includes(tableId), 'Unknown conditional table');
          paramsOnly(url, ['where']);
          const where = url.searchParams.get('where');
          assert.match(where || '', /^\(Id,eq,[1-9]\d*\)~and\(app_sync_revision,eq,[0-9a-f-]{36}\)$/);
          call.body = JSON.parse(init.body);
          assert.match(call.body.app_sync_revision || '', /^[0-9a-f-]{36}$/);
          assert(!Object.hasOwn(call.body, 'Id'));
          for (const key of Object.keys(call.body)) {
            assert(schemas[tableId].some((column) => column.title === key), `Unknown write column: ${key}`);
          }
          const pendingRace = race;
          if (pendingRace) {
            if (++pendingRace.arrivals === 2) { race = null; pendingRace.release(); }
            await pendingRace.ready;
          }
          const matched = rows[tableId].filter((row) => matches(where, row));
          call.matched = matched.length;
          for (const row of matched) {
            Object.assign(row, call.body, { UpdatedAt: '2026-09-02T10:00:00.000Z' });
          }
          if (loseNextResponse) { loseNextResponse = false; throw new Error('SIMULATED_RESPONSE_LOST_AFTER_COMMIT'); }
          return json({ count: matched.length });
        }
        assert.fail(`Unknown REST call: ${method} ${url.pathname}`);
      } catch (error) {
        if (error.message !== 'SIMULATED_RESPONSE_LOST_AFTER_COMMIT') violations.push(error.message);
        throw error;
      }
    },
  };
}
