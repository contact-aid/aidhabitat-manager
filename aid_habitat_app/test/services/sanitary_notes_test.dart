import 'dart:convert';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/sanitary_notes.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late NoteRepository repo;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repo = NoteRepository(database: local);
  });
  tearDown(() => db.close());

  test(
    'legacy drawing pages remain readable without writes; room edits and deletions stay independent',
    () async {
      for (var page = 0; page < 2; page++) {
        await repo.saveDrawingJson(
          patientId: 'p',
          tabKey: sanitaryTextTabKey,
          pageNumber: page,
          drawingJson: jsonEncode({
            'text': 'Observation commune',
            'strokes': [
              {'legacyPage': page},
            ],
          }),
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
      }
      Future<Map<String, dynamic>> read(String key, [int page = 0]) async =>
          jsonDecode(
            (await repo.fetchDrawingJson(
              patientId: 'p',
              tabKey: key,
              pageNumber: page,
            ))!,
          );
      final before = await db.query('sync_operations');
      for (final key in [bathroomDrawingTabKey, wcDrawingTabKey]) {
        expect((await read(key, 1))['strokes'], [
          {'legacyPage': 1},
        ]);
        expect((await read(key, 1))['text'], '');
      }
      expect(await db.query('sync_operations'), before);
      await repo.saveDrawingJson(
        patientId: 'p',
        tabKey: wcDrawingTabKey,
        pageNumber: 1,
        drawingJson: '{"text":"","strokes":[],"deleted":true}',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      expect((await read(wcDrawingTabKey, 1))['deleted'], true);
      expect((await read(bathroomDrawingTabKey, 1))['strokes'], [
        {'legacyPage': 1},
      ]);
      expect((await read(sanitaryTextTabKey))['text'], 'Observation commune');
      await repo.saveDrawingJson(
        patientId: 'p',
        tabKey: bathroomDrawingTabKey,
        drawingJson: '{"text":"","strokes":[]}',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      expect((await read(bathroomDrawingTabKey))['strokes'], isEmpty);
      expect((await read(wcDrawingTabKey))['strokes'], [
        {'legacyPage': 0},
      ]);
      expect((await read(sanitaryTextTabKey))['noteTextInitialized'], true);
    },
  );
}
