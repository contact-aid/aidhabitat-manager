import { StandardFonts, rgb } from 'pdf-lib';

const text = value => value == null ? '' : String(value).trim();
const present = value => value !== undefined && value !== null && value !== '';
const yesNo = value => value === true ? 'Oui' : value === false ? 'Non' : '';
const cm = value => present(value) ? `${value} cm` : '';
const levels = { basement: 'Sous-sol', rdc: 'RDC', floor: '1er étage', second_floor: '2e étage', third_floor: '3e étage', pieces_de_vie: 'Niveau des pièces de vie' };
const list = value => Array.isArray(value) ? value : [];

// Existing page 6 shows only three rooms and no per-room observations, exact
// floor labels or secondary equipment heights. Do not add an empty annex to
// historical single-room reports.
export function needsSanitaryRoomsAppendix(sanitaires = {}) {
  return ['sdbInstances', 'wcInstances'].some(key => {
    const rooms = list(sanitaires?.[key]);
    if (rooms.length <= 1) return false;
    if (rooms.length > 3) return true;
    return rooms.some(room => text(room?.observationEquipementsUtilisation)
      || text(room?.observations)
      || text(room?.levelLabel)
      || ['basement', 'second_floor', 'third_floor'].includes(room?.levelField)
      || ['sdbVasqueSuspendueHauteur', 'sdbVasqueColonneHauteur', 'sdbMeubleVasqueHauteur',
        'sdbBidetHauteur', 'sdbParoiDoucheHauteur', 'sdbMachineALaverHauteur']
        .some(field => present(room?.[field])));
  });
}

function details(room, bathroom) {
  const rows = [];
  const add = (label, value) => { if (text(value)) rows.push(`${label} : ${value}`); };
  add('Niveau', text(room.levelLabel) || levels[room.levelField] || text(room.levelField));
  if (bathroom) {
    for (const [field, label] of [
      ['sdbBaignoire', 'Baignoire'], ['sdbBacDouche', 'Bac à douche'],
      ['sdbVasqueSuspendue', 'Vasque suspendue'], ['sdbVasqueColonne', 'Vasque sur colonne'],
      ['sdbMeubleVasque', 'Meuble vasque'], ['sdbBidet', 'Bidet'],
      ['sdbParoiDouche', 'Paroi de douche'], ['sdbMachineALaver', 'Machine à laver'],
    ]) {
      add(label, yesNo(room[field]));
      add(`Hauteur — ${label}`, cm(room[`${field}Hauteur`]));
    }
    add('Sol glissant', yesNo(room.sdbSolGlissant));
  } else {
    add('Hauteur cuvette', cm(room.wcCuvetteHauteur));
    add('Cuvette à bonne hauteur', yesNo(room.wcCuvetteBonneHauteur));
    add('Cuvette trop basse', yesNo(room.wcCuvetteTropBasse));
    add('Cuvette trop haute', yesNo(room.wcCuvetteTropHaute));
    add('Barre de relèvement', yesNo(room.wcBarreRelevement));
  }
  const prefix = bathroom ? 'porteSdb' : 'porteWc';
  add('Largeur de porte suffisante', yesNo(room[`${prefix}LargeurSuffisante`]));
  add('Dimension de porte', cm(room[`${prefix}Dimension`]));
  add("Sens d’ouverture", room[`${prefix}SensAdapte`] === true ? 'Intérieur' : room[`${prefix}SensAdapte`] === false ? 'Extérieur' : '');
  add('Observations équipements / utilisation', text(room.observationEquipementsUtilisation));
  add('Observations', text(room.observations));
  return rows;
}

/** Pure PDF output: never writes back, generates IDs, sorts or deduplicates rooms. */
export async function appendSanitaryRoomsAppendix({ pdfDoc, sanitaires = {} }) {
  if (!needsSanitaryRoomsAppendix(sanitaires)) return 0;
  const regular = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  let page, y, count = 0, currentRoom = '';
  const ink = rgb(0.12, 0.12, 0.12);
  // Match the main report's standard-font encoding, replacing only unsupported
  // glyphs instead of failing the entire report on a pasted symbol.
  const printable = value => [...text(value)].map(char => {
    if (char === '\n') return char;
    try { regular.encodeText(char); return char; } catch { return '?'; }
  }).join('');
  function newPage(continuation = false) {
    page = pdfDoc.addPage([595.28, 841.89]); count++;
    page.drawText('Annexe — Détail des sanitaires', { x: 42, y: 794, size: 15, font: bold, color: ink });
    page.drawText(`Sanitaires — ${count}`, { x: 42, y: 27, size: 9, font: regular, color: ink });
    y = 766;
    if (continuation && currentRoom) {
      page.drawText(`${currentRoom} (suite)`, { x: 42, y, size: 12, font: bold, color: ink });
      y -= 20;
    }
  }
  function line(value, heading = false) {
    if (!page || y < 55) newPage(Boolean(page));
    page.drawText(value, { x: 42, y, size: heading ? 12 : 10, font: heading ? bold : regular, color: ink });
    y -= heading ? 20 : 14;
  }
  function write(value, heading = false) {
    const font = heading ? bold : regular;
    const size = heading ? 12 : 10;
    for (const paragraph of printable(value).split('\n')) {
      let pending = '';
      for (const char of paragraph) {
        if (font.widthOfTextAtSize(pending + char, size) > 510) {
          const space = pending.lastIndexOf(' ');
          if (space > 0) { line(pending.slice(0, space), heading); pending = pending.slice(space + 1); }
          else { line(pending, heading); pending = ''; }
        }
        pending += char;
      }
      line(pending, heading);
    }
  }
  for (const [key, label, bathroom] of [['sdbInstances', 'Salle de bain', true], ['wcInstances', 'WC', false]]) {
    for (const [index, value] of list(sanitaires?.[key]).entries()) {
      const room = value && typeof value === 'object' ? value : {};
      if (page && y < 95) newPage();
      currentRoom = `${label} ${index + 1}`;
      write(currentRoom, true);
      for (const row of details(room, bathroom)) write(row);
      y -= 12;
    }
  }
  return count;
}
