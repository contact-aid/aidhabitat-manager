import 'dart:convert';

import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('missing remote page can be requeued only after a verified absence', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''CREATE TABLE sync_operations (
      id TEXT PRIMARY KEY, entity_type TEXT, entity_local_id TEXT,
      payload_json TEXT, status TEXT, attempt_count INTEGER,
      last_error TEXT, updated_at TEXT)''');
    await db.execute('''CREATE TABLE note_pages (
      local_id TEXT PRIMARY KEY, remote_revision TEXT, sync_state TEXT,
      drawing_json TEXT)''');
    const noteId = 'note_patient_Plans_1';
    const drawing = '{"text":"synthetic local edit","strokes":[{"x":1}]}';
    await db.insert('note_pages', {
      'local_id': noteId,
      'remote_revision': '00000000-0000-4000-8000-000000000001',
      'sync_state': 'conflict',
      'drawing_json': drawing,
    });
    await db.insert('sync_operations', {
      'id': 'op-1', 'entity_type': 'note_page',
      'entity_local_id': noteId, 'status': 'conflict',
      'attempt_count': 0,
      'payload_json': jsonEncode({
        'patientLocalId': 'patient', 'tabKey': 'Plans', 'pageNumber': 1,
        'drawingJson': drawing,
        'expectedRevision': '00000000-0000-4000-8000-000000000001',
        'writeId': '00000000-0000-4000-8000-000000000002',
        'conflict': {'remote': {'error': 'NOTE_PAGE_RECORD_MISSING'}},
      }),
    });
    final repository = SyncRepository.forTesting(databaseProvider: () async => db);
    expect(await repository.resolveNoteConflictKeepingLocal('op-1'), isFalse);
    final operation = (await db.query('sync_operations')).single;
    expect(operation['status'], 'conflict');
    expect((await db.query('note_pages')).single['drawing_json'], drawing);

    expect(
      await repository.resolveNoteConflictKeepingLocal(
        'op-1',
        verifiedRemoteMissing: true,
      ),
      isTrue,
    );
    final requeued = (await db.query('sync_operations')).single;
    final payload = jsonDecode(requeued['payload_json'] as String) as Map;
    expect(requeued['status'], 'pending');
    expect(requeued['attempt_count'], 0);
    expect(payload['drawingJson'], drawing);
    expect(payload['expectedRevision'], isNull);
    expect(payload['writeId'], isNot('00000000-0000-4000-8000-000000000002'));
    expect(payload.containsKey('conflict'), isFalse);
    expect((await db.query('note_pages')).single['drawing_json'], drawing);
    expect((await db.query('note_pages')).single['remote_revision'], isNull);
    expect(
      await repository.resolveNoteConflictKeepingLocal(
        'op-1',
        verifiedRemoteMissing: true,
      ),
      isFalse,
    );

    await db.insert('sync_operations', {
      'id': 'op-2', 'entity_type': 'note_page',
      'entity_local_id': noteId, 'status': 'conflict',
      'attempt_count': 0,
      'payload_json': jsonEncode({
        'drawingJson': drawing,
        'expectedRevision': '00000000-0000-4000-8000-000000000001',
        'writeId': '00000000-0000-4000-8000-000000000003',
        'conflict': {'remote': {'error': 'NOTE_PAGE_WRITE_ID_REUSED'}},
      }),
    });
    expect(
      await repository.resolveNoteConflictKeepingLocal(
        'op-2',
        verifiedRemoteMissing: true,
      ),
      isFalse,
    );
  });
}
