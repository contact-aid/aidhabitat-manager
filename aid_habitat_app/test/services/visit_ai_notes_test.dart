import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/visit_ai_notes.dart';
import 'package:aid_habitat_app/services/visit_assistant_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  late NoteRepository notes;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    notes = NoteRepository(database: local);
  });
  tearDown(() => db.close());
  Future<void> save(Map<String, dynamic> drawing) => notes.saveDrawingJson(
    patientId: 'patient',
    dossierId: 'dossier',
    tabKey: 'Accessibilité-Notes',
    drawingJson: jsonEncode(drawing),
    mutationOrigin: SyncMutationOrigin.userEdit,
  );
  Future<Map<String, dynamic>> read() async =>
      jsonDecode(
            (await notes.fetchDrawingJson(
              patientId: 'patient',
              dossierId: 'dossier',
              tabKey: 'Accessibilité-Notes',
            ))!,
          )
          as Map<String, dynamic>;
  Future<void> append() => notes.appendVisitText(
    patientId: 'patient',
    dossierId: 'dossier',
    tabKey: 'Accessibilité-Notes',
    recordingId: 'recording',
    text: 'Complément IA',
  );

  test(
    'automatic text appends verbatim after keyboard text, preserving strokes and one sync mutation',
    () async {
      final drawing = {
        'version': 1,
        'text': 'Saisie humaine  \n',
        'strokes': [
          {'x': 1},
        ],
        'medicalFlags': [2],
      };
      await save(drawing);
      await append();
      await append();
      final result = await read();
      expect(result['text'], 'Saisie humaine  \n\n\nComplément IA');
      expect(result['strokes'], drawing['strokes']);
      expect(result['medicalFlags'], [2]);
      expect(await db.query('visit_ai_receipts'), hasLength(1));
      final operations = await db.query(
        'sync_operations',
        where: 'entity_type = ?',
        whereArgs: ['note_page'],
      );
      expect(operations, hasLength(1));
      expect(
        jsonDecode(operations.single['payload_json'] as String)['drawingJson'],
        isNotEmpty,
      );
    },
  );
  test(
    'a stale editor cannot erase the insertion; an informed human edit may remove it',
    () async {
      await save({'text': 'Première saisie', 'strokes': []});
      await append();
      await save({
        'text': 'Première saisie, puis frappe en cours',
        'strokes': [],
      });
      var drawing = await read();
      expect(
        drawing['text'],
        'Première saisie, puis frappe en cours\n\nComplément IA',
      );
      drawing['text'] = 'Version relue et corrigée';
      await save(drawing);
      await append();
      expect((await read())['text'], 'Version relue et corrigée');
    },
  );
  test(
    'receipt and insertion roll back together on an ownership conflict',
    () async {
      await save({'text': 'Original', 'strokes': []});
      await expectLater(
        notes.appendVisitText(
          patientId: 'patient',
          dossierId: 'another-dossier',
          tabKey: 'Accessibilité-Notes',
          recordingId: 'recording',
          text: 'Ajout',
        ),
        throwsStateError,
      );
      expect((await read())['text'], 'Original');
      expect(await db.query('visit_ai_receipts'), isEmpty);
    },
  );
  test(
    'two completed recordings append once each, including after local restart',
    () async {
      await save({'text': 'Saisie', 'strokes': []});
      await append();
      await notes.appendVisitText(
        patientId: 'patient',
        dossierId: 'dossier',
        tabKey: 'Accessibilité-Notes',
        recordingId: 'recording-2',
        text: 'Deuxième visite',
      );
      final restarted = NoteRepository(database: local);
      await restarted.appendVisitText(
        patientId: 'patient',
        dossierId: 'dossier',
        tabKey: 'Accessibilité-Notes',
        recordingId: 'recording-2',
        text: 'Deuxième visite',
      );
      expect(
        (await read())['text'],
        'Saisie\n\nComplément IA\n\nDeuxième visite',
      );
    },
  );
  test('local recording queue is scoped to the signed-in owner', () async {
    final store = VisitAssistantStore(database: local);
    await store.save({
      'id': 'a',
      'owner': 'coralie',
      'dossierId': 'd',
      'segments': ['retained'],
    });
    await store.save({
      'id': 'b',
      'owner': 'christelle',
      'dossierId': 'd',
      'segments': [],
    });
    expect((await store.list('coralie')).single['segments'], ['retained']);
    expect((await store.list('christelle')).single['id'], 'b');
    expect(await store.list('other'), isEmpty);
  });
}
