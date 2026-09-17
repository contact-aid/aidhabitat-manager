import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import ts from 'typescript';

// Inspect syntax, rather than matching source text, so every mapped column is
// checked even when a mapper gains a new property or changes formatting.
const source = ts.createSourceFile('index.mjs', await readFile(new URL('./index.mjs', import.meta.url), 'utf8'),
  ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
const find = (root, predicate) => {
  if (predicate(root)) return root;
  return ts.forEachChild(root, (child) => find(child, predicate));
};
const variable = (root, name) => find(root, (node) => ts.isVariableDeclaration(node) && node.name.getText(source) === name);
const propertyName = (node) => node.name && (ts.isStringLiteral(node.name) ? node.name.text : node.name.getText(source));
const projections = variable(source, 'FIELD_SETS').initializer;
const route = (url) => find(source, (node) => ts.isCallExpression(node)
  && node.expression.getText(source) === 'app.put' && node.arguments[0]?.text === url);
for (const [table, mapper, fieldsVariable] of [
  ['beneficiaires', 'mapBeneficiaryUpdatesToFields'],
  ['logements', 'mapHousingFields'],
  ['dossiers', 'mapDossierFields'],
  ['contexteDeVie', 'upsertContexte', 'fields'],
  ['diagnosticSanitaires', '/api/diagnostic-sanitaires/:dossierId', 'fields'],
  ['mesuresAnthropometriques', '/api/mesures/:dossierId', 'fields'],
  ['observations', '/api/observations/:dossierId', 'fields'],
]) {
  test(`${table}: all editable mapped columns are included in the read projection`, () => {
    const owner = mapper.startsWith('/') ? route(mapper) : variable(source, mapper);
    assert(owner, mapper);
    const root = fieldsVariable ? variable(owner, fieldsVariable).initializer
      : find(owner, (node) => ts.isCallExpression(node)
        && node.expression.getText(source) === 'sanitizeUndefined').arguments[0];
    const columns = new Set();
    const walk = (node) => {
      if (ts.isPropertyAssignment(node)) { columns.add(propertyName(node)); return; }
      ts.forEachChild(node, walk);
    };
    walk(root);
    const projection = projections.properties.find((node) => propertyName(node) === table).initializer;
    const read = new Set(projection.elements.map((node) => node.text));
    // Link identities and creation metadata are not user-editable baselines.
    const metadata = new Set(['uuid_source', 'beneficiaire_id', 'beneficiaires_id', 'dossier_id', 'dossiers_id', 'created_at']);
    const missing = [...columns].filter((key) => !metadata.has(key) && !read.has(key));
    assert.deepEqual(missing, [], `${table}: missing comparison columns`);
    assert(columns.size > 3, 'the test must inspect an actual field mapper');
  });
}
