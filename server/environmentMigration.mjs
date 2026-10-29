import crypto from 'node:crypto';

export const ENVIRONMENT_MIGRATION = 'environment-legacy-20261029';
const sourceKey = 'Contexte de vie-Médical';
const targetKey = 'Bénéficiaire-Notes';
const drawingOf = page => JSON.parse(page?.drawingJson || '{}');
export const environmentSnapshotHash = value => crypto.createHash('sha256')
  .update(JSON.stringify(value)).digest('hex');

// Pure, reviewable plan. Historical rows and handwriting are never changed.
export function planEnvironmentMigration({ pages, dossiers }) {
  const groups = new Map();
  for (const page of pages) {
    if (page.tabKey !== sourceKey) continue;
    if (!page.patientId || !page.dossierId) throw new Error('Missing source identity');
    const key = JSON.stringify([page.patientId, page.dossierId]);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(page);
  }
  const writes = [], skipped = [];
  for (const sources of groups.values()) {
    const {patientId, dossierId} = sources[0];
    const texts = [], seen = new Set(), numbers = new Set();
    for (const page of [...sources].sort((a,b) => a.pageNumber-b.pageNumber)) {
      if (page.scopeType !== 'dossier_detail' || page.subTabKey
          || ![patientId, dossierId].includes(page.scopeId)
          || numbers.has(page.pageNumber)) throw new Error('Ambiguous source scope/pages');
      numbers.add(page.pageNumber);
      const drawing = drawingOf(page);
      if (drawing.deleted === true) continue;
      const text = drawing.noteTextInitialized === true && typeof drawing.text === 'string'
        ? drawing.text : String(drawing.text || page.textContent || '');
      const normalized = text.trim().replace(/\s+/g, ' ').toLowerCase();
      if (normalized && !seen.has(normalized)) {seen.add(normalized);texts.push(text.trim());}
    }
    if (!texts.length) {skipped.push({patientId,dossierId,reason:'empty-source'});continue;}
    const dossier = dossiers.filter(r => r.fields.uuid_source === dossierId);
    if (dossier.length !== 1 || dossier[0].fields.patient_id !== patientId) {
      throw new Error('Dossier/patient link mismatch');
    }
    const targets = pages.filter(p => p.patientId === patientId && p.dossierId === dossierId
      && p.tabKey === targetKey);
    const targetPages = new Set();
    for (const page of targets) {
      if (page.scopeType !== 'dossier_detail' || page.scopeId !== dossierId || page.subTabKey
          || targetPages.has(page.pageNumber)) throw new Error('Ambiguous destination');
      targetPages.add(page.pageNumber);
      drawingOf(page);
    }
    const target = targets.find(p => Number(p.pageNumber) === 0);
    if (target && !target.revision) throw new Error('Missing destination revision');
    const drawing = drawingOf(target);
    if (drawing.environmentLegacyMigration === ENVIRONMENT_MIGRATION) {
      skipped.push({patientId,dossierId,reason:'already-migrated'});continue;
    }
    if (drawing.deleted === true) throw new Error('Deleted destination requires review');
    const text = texts.join('\n\n');
    const sourceId = crypto.createHash('sha256').update(`${ENVIRONMENT_MIGRATION}:${patientId}:${dossierId}`).digest('hex');
    const notePageId = target?.id ?? `${sourceId.slice(0,8)}-${sourceId.slice(8,12)}-5${sourceId.slice(13,16)}-a${sourceId.slice(17,20)}-${sourceId.slice(20,32)}`;
    writes.push({sources, before:target ?? null, destinationsBefore:targets,
      sourceHash:environmentSnapshotHash(sources),
      payload:{...target, notePageId,patientId,dossierId,scopeType:'dossier_detail',scopeId:dossierId,
        subTabKey:'',tabKey:targetKey,pageNumber:0,textContent:text,
        drawingJson:JSON.stringify({...drawing,version:drawing.version??1,strokes:drawing.strokes??[],
          text,noteTextInitialized:true,contextTextV2Initialized:true,
          environmentLegacyMigration:ENVIRONMENT_MIGRATION}),
        previewDataUrl:target?.previewDataUrl??'',layoutKind:target?.layoutKind??'freeform',
        expectedRevision:target?.revision??null,writeId:crypto.randomUUID()}});
  }
  return {writes,skipped};
}
