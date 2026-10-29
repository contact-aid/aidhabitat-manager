import 'dart:convert';
import 'package:aid_habitat_app/services/context_notes.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
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
    for (final (key, page, text) in [
      (environmentTextTabKey, 0, 'Projet : adapter la douche.'),
      (medicalDrawingTabKey, 0, 'Maison isolée.'),
      (medicalDrawingTabKey, 1, 'Maison isolée.'),
      (autonomyDrawingTabKey, 0, 'Courses chaque semaine.'),
      (autonomyDrawingTabKey, 1, 'Marche quotidienne.'),
    ]) {
      await repo.mergeRemoteNotePage(
        patientId: 'p',
        dossierId: 'd',
        tabKey: key,
        pageNumber: page,
        drawingJson: jsonEncode({
          'version': 1,
          'text': text,
          'strokes': [
            {'source': key, 'page': page},
          ],
        }),
        revision: '00000000-0000-4000-8000-000000000001',
      );
    }
  });
  tearDown(() => db.close());
  Future<Map<String, dynamic>> read(String key) async => jsonDecode(
    (await repo.fetchDrawingJson(patientId: 'p', dossierId: 'd', tabKey: key))!,
  );
  test('migration reads preserve prose and drawings without writing', () async {
    final before = await db.query('note_pages');
    final ops = await db.query('sync_operations');
    final env = await read(environmentTextTabKey);
    expect(env['text'], 'Projet : adapter la douche.\n\nMaison isolée.');
    expect(env['strokes'], [
      {'source': environmentTextTabKey, 'page': 0},
    ]);
    expect(
      (await read(habitsTextTabKey))['text'],
      'Courses chaque semaine.\n\nMarche quotidienne.',
    );
    expect((await read(habitsTextTabKey))['strokes'], isEmpty);
    expect(await db.query('note_pages'), before);
    expect(await db.query('sync_operations'), ops);
  });
  test('edits and explicit clears suppress obsolete legacy prose', () async {
    final medical = await read(medicalDrawingTabKey);
    for (final key in [environmentTextTabKey, habitsTextTabKey]) {
      for (final text in ['Correction validée', '']) {
        final drawing = await read(key);
        await repo.saveDrawingJson(
          patientId: 'p',
          dossierId: 'd',
          tabKey: key,
          drawingJson: jsonEncode({...drawing, 'text': text}),
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
        expect((await read(key))['text'], text);
        expect((await read(key))[contextTextInitializedKey], true);
      }
    }
    expect(await read(medicalDrawingTabKey), medical);
  });
  test(
    'medical drawing changes do not alter autonomy or typed habits',
    () async {
      final auto = await read(autonomyDrawingTabKey);
      final habits = await read(habitsTextTabKey);
      final medical = await read(medicalDrawingTabKey);
      await repo.saveDrawingJson(
        patientId: 'p',
        dossierId: 'd',
        tabKey: medicalDrawingTabKey,
        drawingJson: jsonEncode({...medical, 'strokes': []}),
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      expect(await read(autonomyDrawingTabKey), auto);
      expect(await read(habitsTextTabKey), habits);
    },
  );
  test(
    'assistant additions seed canonical prose before appending once',
    () async {
      await repo.appendVisitText(
        patientId: 'p',
        dossierId: 'd',
        tabKey: habitsTextTabKey,
        recordingId: 'synthetic-recording',
        text: 'Complément de visite.',
      );
      final text = (await read(habitsTextTabKey))['text'] as String;
      expect(text, contains('Courses chaque semaine.'));
      expect(text, contains('Marche quotidienne.'));
      expect(text, contains('Complément de visite.'));
      await repo.appendVisitText(
        patientId: 'p',
        dossierId: 'd',
        tabKey: habitsTextTabKey,
        recordingId: 'synthetic-recording',
        text: 'Complément de visite.',
      );
      expect((await read(habitsTextTabKey))['text'], text);
    },
  );
  test('other dossier prose is excluded', () async {
    final raw = await repo.fetchDrawingJson(
      patientId: 'p',
      dossierId: 'other',
      tabKey: habitsTextTabKey,
    );
    expect(jsonDecode(raw!)['text'], '');
  });
}
