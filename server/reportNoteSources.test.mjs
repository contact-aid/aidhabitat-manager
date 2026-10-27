import assert from 'node:assert/strict';
import test from 'node:test';
import { joinReportNotePagesText } from './reports/noteText.mjs';
import { splitRetirementFundNames, retirementFundLabelsForReport } from './reports/retirementFundNames.mjs';

const page = (number, text, strokes = []) => ({
  pageNumber: number,
  drawingJson: JSON.stringify({ version: 1, text, strokes }),
});

test('four handwritten pages print their shared written note once without mutating drawings', () => {
  const pages = Array.from({ length: 4 }, (_, i) => page(i,
    'Entrée accessible par une rampe.\nCirculation à sécuriser.',
    [{ points: [{ x: i / 10, y: 0.2 }] }],
  ));
  const before = structuredClone(pages);
  assert.equal(joinReportNotePagesText(pages),
    'Entrée accessible par une rampe.\nCirculation à sécuriser.');
  assert.deepEqual(pages, before);
});

test('distinct legacy pages remain ordered; whitespace copies do not repeat', () => {
  const pages = [page(2, '  Première   observation. '), page(1, 'Deuxième observation.'), page(0, 'Première observation.')];
  assert.equal(joinReportNotePagesText(pages), 'Première observation.\n\nDeuxième observation.');
  assert.equal(pages[0].pageNumber, 2);
});

test('legacy textContent remains readable and deleted drawings do not return', () => {
  assert.equal(joinReportNotePagesText([
    { pageNumber: 0, drawingJson: 'invalid legacy JSON', textContent: 'Texte historique' },
    { pageNumber: 1, drawingJson: JSON.stringify({ text: 'Effacé', deleted: true }), textContent: 'Effacé' },
    page(2, ''),
  ]), 'Texte historique');
});

test('retirement multi-selections from each occupant split semicolons, commas and newlines', () => {
  assert.deepEqual(splitRetirementFundNames(['Fonds A; Fonds B', 'Fonds A, Fonds C\nFonds D']),
    ['Fonds A', 'Fonds B', 'Fonds A', 'Fonds C', 'Fonds D']);
  assert.deepEqual(splitRetirementFundNames('Fonds A'), ['Fonds A']);
  assert.deepEqual(splitRetirementFundNames([null, '', ' ; , ']), []);
});


test('the report lists all complementary funds once, regardless of occupant or aid flag', () => {
  assert.equal(retirementFundLabelsForReport(['IRCANTEC; AG2R', 'IRCANTEC; ircem']),
    'IRCANTEC, AG2R, ircem sous conditions*');
  assert.equal(retirementFundLabelsForReport(['AG2R; ag2r', 'AG2R']), 'AG2R sous conditions*');
  assert.equal(retirementFundLabelsForReport(['Fonds A', 'Fonds B']),
    'Fonds A, Fonds B sous conditions*');
  assert.equal(retirementFundLabelsForReport(['', null]), '/');
});


test('sanitary keyboard edits ignore old handwritten page texts, including after clearing', () => {
  const pages = [
    { ...page(0, 'Observation commune'), drawingJson: JSON.stringify({ text: 'Observation commune', noteTextInitialized: true }) },
    page(1, 'Ancien texte page 2'),
  ];
  assert.equal(joinReportNotePagesText(pages, { canonicalPageZero: true }), 'Observation commune');
  pages[0].drawingJson = JSON.stringify({ text: '', noteTextInitialized: true });
  pages[0].textContent = 'Ancien texte ordinateur';
  assert.equal(joinReportNotePagesText(pages, { canonicalPageZero: true }), '');
});
