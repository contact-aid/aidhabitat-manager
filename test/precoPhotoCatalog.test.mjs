import test from 'node:test';
import assert from 'node:assert/strict';
import { photoMetadata } from '../tools/precoPhotoCatalog.mjs';

test('titles preserve the filename meaning and remove transport suffixes', () => {
  assert.equal(photoMetadata('1_ SDB/Douche/douche adaptée 2.jpg').title, 'Douche adaptée 2');
  assert.equal(photoMetadata('5_ Portes/rideau-de-porte-isolant-thermique-54224415162703_1800x1800.jpg').title, 'Rideau de porte isolant thermique');
});
test('decomposed filenames produce the same metadata', () => {
  const file = '1_ SDB/Douche/siège douche mural.jpg';
  assert.deepEqual(photoMetadata(file.normalize('NFD')), photoMetadata(file));
});
test('unknown equipment is rejected instead of inventing a description', () => {
  assert.throws(() => photoMetadata('1_ SDB/inconnu.jpg'), /Description missing/);
});
test('known folders map onto existing library filters', () => {
  for (const [file, tag] of [
    ['1_ SDB/Douche/siège douche mural.jpg', 'Salle de bain'],
    ['2_ WC/Cadre WC .jpg', 'WC'],
    ["3_ Barre d'appui/Barre relevable.jpg", "Barres d'appui"],
    ['5_ Ascenseur/ascenseur.jpeg', 'Escaliers & ascenseur'],
    ['6_ Extérieur/portillon.jpg', 'Accès extérieurs'],
    ['5_ Portes/porte pliante.jpg', 'Ouvertures'],
    ['9_ Cuisine/four porte escamotable.png', 'Cuisine'],
    ['15_ Aide technique Hors sdb/ouvre-bocal.jpg', 'Equipements'],
  ]) {
    const meta = photoMetadata(file);
    assert.equal(meta.category, tag);
    assert.deepEqual(meta.tags, [tag]);
    assert.ok(meta.description.length > 60);
  }
});
