import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'a newer remote note cannot overwrite unpublished local content',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = NoteRepository(database: local);
      await db.insert('note_pages', {
        'local_id': 'note_patient_Contexte_0',
        'patient_local_id': 'patient',
        'tab_key': 'Contexte',
        'page_number': 0,
        'drawing_json': '{}',
        'text_content': 'Local edit',
        'updated_at': '2026-09-01T10:00:00.000Z',
        'sync_state': 'pendingSync',
      });

      final merged = await repository.mergeRemoteNotePage(
        patientId: 'patient',
        tabKey: 'Contexte',
        pageNumber: 0,
        drawingJson: '{}',
        textContent: 'Remote edit',
        updatedAt: '2026-09-02T10:00:00.000Z',
      );

      expect(merged, isFalse);
      final note = (await db.query('note_pages')).single;
      expect(note['text_content'], 'Local edit');
      expect(note['sync_state'], 'pendingSync');
    },
  );
}
