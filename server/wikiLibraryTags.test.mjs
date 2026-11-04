import test from 'node:test';
import assert from 'node:assert/strict';
import { WIKI_FILTER_TAGS } from './wikiLibraryCatalog.mjs';
import { resolveWikiPrimaryTag } from './wikiLibraryTags.mjs';

test('keeps Autre on a new entry whose description suggests Chambre', () => {
  const item = {
    title: 'Pastilles contrastées en relief',
    description: 'Faciliter le repérage et améliorer la visibilité.',
    category: 'Autre',
    tags: ['Autre'],
  };
  assert.equal(resolveWikiPrimaryTag({ ...item, tags: [] }), 'Chambre');
  for (let i = 0; i < 4; i++) {
    item.tags = [resolveWikiPrimaryTag(item)];
    assert.deepEqual(item.tags, ['Autre']);
  }
});

test('changing a previously inferred tag to Autre persists across rereads', () => {
  const item = { title: 'Douche de plain-pied', description: '', category: 'Salle de bain', tags: ['Autre'] };
  assert.equal(resolveWikiPrimaryTag(item), 'Autre');
  assert.equal(resolveWikiPrimaryTag({ ...item, tags: ['Autres'] }), 'Autre');
  assert.equal(resolveWikiPrimaryTag({ ...item, tags: [' autre '] }), 'Autre');
});

test('all offered canonical tags take priority over conflicting keywords', () => {
  assert.ok(WIKI_FILTER_TAGS.includes('Autre'));
  for (const tag of WIKI_FILTER_TAGS) {
    assert.equal(resolveWikiPrimaryTag({ title: 'WC douche cuisine chambre', tags: [tag] }), tag);
  }
});

test('retains legacy inference for entries without a recognized explicit tag', () => {
  assert.equal(resolveWikiPrimaryTag({ title: 'Douche', tags: [] }), 'Salle de bain');
  assert.equal(resolveWikiPrimaryTag({ title: 'Main courante', tags: ['Historique'] }), "Barres d'appui");
  assert.equal(resolveWikiPrimaryTag({ title: 'Divers' }), 'Equipements');
});
