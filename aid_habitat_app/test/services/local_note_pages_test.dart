import 'dart:convert';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
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
  test('blank legacy notes can be saved without JSON parse failure', () async {
    await repo.saveDrawingJson(
      patientId: 'p',
      dossierId: 'd',
      tabKey: 'notes_rapides',
      drawingJson: '',
      mutationOrigin: SyncMutationOrigin.userEdit,
    );
    final raw = await repo.fetchDrawingJson(
      patientId: 'p',
      tabKey: 'notes_rapides',
    );
    expect(jsonDecode(raw!)['noteTextInitialized'], isTrue);
  });
  test(
    'exhaustive read and atomic duplicate keep holes, metadata and original queue',
    () async {
      const drawing =
          '{"type":"plan_canvas_v1","pageKind":"blank","unknown":{"preserve":true}}';
      for (final page in [0, 4, 120]) {
        await repo.saveDrawingJson(
          patientId: 'p',
          dossierId: 'd',
          tabKey: 'Plans',
          pageNumber: page,
          drawingJson: drawing,
          previewDataUrl: 'data:image/png;base64,ZmljdGlvbg==',
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
      }
      await db.update(
        'note_pages',
        {
          'text_content': await OfflineVault.instance.sealString(
            'Texte fictif',
          ),
        },
        where: 'page_number = ?',
        whereArgs: [4],
      );
      final beforeNotes = await db.query('note_pages');
      final beforeOps = await db.query('sync_operations');
      final pages = await repo.fetchLocalNotePages(
        patientId: 'p',
        dossierId: 'd',
      );
      expect(pages.map((p) => p.pageNumber), [0, 4, 120]);
      expect(pages.every((p) => p.planPhase == null), isTrue);
      expect(await db.query('note_pages'), beforeNotes);
      expect(await db.query('sync_operations'), beforeOps);
      final number = await repo.duplicateLocalNotePage(
        patientId: 'p',
        dossierId: 'd',
        sourcePageNumber: 4,
      );
      expect(number, 121);
      expect(
        await db.query(
          'note_pages',
          where: 'page_number != ?',
          whereArgs: [121],
        ),
        beforeNotes,
      );
      expect(
        await db.query(
          'sync_operations',
          where: 'entity_local_id != ?',
          whereArgs: ['note_p_Plans_121'],
        ),
        beforeOps,
      );
      final copy = (await repo.fetchLocalNotePages(
        patientId: 'p',
        dossierId: 'd',
      )).last;
      expect(copy.drawingJson, drawing);
      expect(copy.textContent, 'Texte fictif');
      expect(copy.previewDataUrl, pages[1].previewDataUrl);
      expect(copy.planPhase, isNull);
      final queued = (await db.query(
        'sync_operations',
        where: 'entity_local_id = ?',
        whereArgs: ['note_p_Plans_121'],
      )).single;
      final payload = jsonDecode(
        await OfflineVault.instance.openString(
          queued['payload_json'] as String,
        ),
      );
      expect(payload['expectedRevision'], isNull);
      expect(payload['textContent'], 'Texte fictif');
      expect(payload['planPhase'], isNull);
      expect(payload['scopeType'], 'visit_grid');
      await repo.saveDrawingJson(
        patientId: 'p',
        tabKey: 'Plans',
        pageNumber: 121,
        drawingJson: '{"pageKind":"blank","newStroke":true}',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      final afterStroke = (await repo.fetchLocalNotePages(
        patientId: 'p',
        dossierId: 'd',
      )).last;
      expect(afterStroke.textContent, 'Texte fictif');
      expect(afterStroke.planPhase, isNull);
      expect(afterStroke.previewDataUrl, copy.previewDataUrl);
      final row = (await db.query(
        'note_pages',
        where: 'page_number = ?',
        whereArgs: [121],
      )).single;
      expect(row['dossier_local_id'], 'd');
    },
  );
  test(
    'copy refuses missing raster for remote preview without altering source',
    () async {
      await repo.saveDrawingJson(
        patientId: 'p',
        dossierId: 'd',
        tabKey: 'Plans',
        drawingJson: '{}',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      await db.update('note_pages', {
        'drawing_remote_url': 'https://synthetic.invalid/preview',
      });
      final before = await db.query('sync_operations');
      await expectLater(
        repo.duplicateLocalNotePage(
          patientId: 'p',
          dossierId: 'd',
          sourcePageNumber: 0,
        ),
        throwsStateError,
      );
      expect(await db.query('sync_operations'), before);
      expect((await db.query('note_pages')).length, 1);
    },
  );
}
