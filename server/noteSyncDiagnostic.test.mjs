import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { noteSyncMetadata, safeNoteErrorCode } from './noteSyncDiagnostic.mjs';
test('note diagnostic correlates identity and bytes without exporting contents', () => {
 const drawingJson = JSON.stringify({text:'private medical note',strokes:Array(40000).fill({x:1,y:2})});
 const body={drawingJson,patientId:'p1',scopeId:'s1',tabKey:'Plans',pageNumber:1,writeId:'w1',previewDataUrl:'private preview',token:'secret'};
 const diagnostic=noteSyncMetadata(body);
 assert.equal(diagnostic.drawingSha256,createHash('sha256').update(drawingJson).digest('hex'));
 assert(diagnostic.storedDrawingCharacters<diagnostic.drawingCharacters);
 assert(!JSON.stringify(diagnostic).includes('private'));
 assert(!JSON.stringify(diagnostic).includes('secret'));
 assert.notEqual(noteSyncMetadata({...body,pageNumber:2}).identitySha256,diagnostic.identitySha256);
 assert.equal(safeNoteErrorCode('private medical note'),'NOTE_PAGE_SERVER_ERROR');
 assert.equal(safeNoteErrorCode('NOTE_PAGE_CONTENT_TOO_LARGE'),'NOTE_PAGE_CONTENT_TOO_LARGE');
});
