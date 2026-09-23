import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  test(
    'hydrating an existing remote note into an empty cache queues nothing',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = NoteRepository(database: local);

      final merged = await repository.mergeRemoteNotePage(
        patientId: 'nocodb-beneficiaire-62',
        dossierId: 'andasse-martine',
        tabKey: 'notes_rapides',
        pageNumber: 0,
        drawingJson: '{"version":1,"text":"note serveur","strokes":[]}',
        revision: 'server-revision-7',
        updatedAt: '2026-09-23T08:00:00.000Z',
      );

      expect(merged, isTrue);
      expect(await db.query('sync_operations'), isEmpty);
      final notes = await db.query('note_pages');
      expect(notes, hasLength(1));
      expect(notes.single['sync_state'], 'synced');
      expect(notes.single['remote_revision'], 'server-revision-7');
    },
  );

  test('re-hydrating and reading an existing note queues nothing', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    final repository = NoteRepository(database: local);
    const drawing = '{"version":1,"text":"canonique","strokes":[]}';

    await repository.mergeRemoteNotePage(
      patientId: 'patient',
      dossierId: 'dossier',
      tabKey: 'notes_rapides',
      pageNumber: 0,
      drawingJson: drawing,
      revision: 'revision-1',
      updatedAt: '2026-09-23T08:00:00.000Z',
    );
    expect(
      await repository.fetchDrawingJson(
        patientId: 'patient',
        dossierId: 'dossier',
        tabKey: 'notes_rapides',
      ),
      drawing,
    );
    await repository.mergeRemoteNotePage(
      patientId: 'patient',
      dossierId: 'dossier',
      tabKey: 'notes_rapides',
      pageNumber: 0,
      drawingJson: drawing,
      revision: 'revision-1',
      updatedAt: '2026-09-23T08:00:00.000Z',
    );

    expect(await db.query('sync_operations'), isEmpty);
    expect(await db.query('note_pages'), hasLength(1));
  });

  test(
    'rapid user edits keep one final mutation with its server baseline',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = NoteRepository(database: local);
      await repository.mergeRemoteNotePage(
        patientId: 'patient',
        dossierId: 'dossier',
        tabKey: 'notes_rapides',
        pageNumber: 0,
        drawingJson: '{"version":1,"text":"base","strokes":[]}',
        revision: 'revision-base',
        updatedAt: '2026-09-23T08:00:00.000Z',
      );

      for (final text in ['A', 'AB', 'ABC']) {
        await repository.saveDrawingJson(
          patientId: 'patient',
          dossierId: 'dossier',
          tabKey: 'notes_rapides',
          drawingJson: '{"version":1,"text":"$text","strokes":[]}',
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
      }

      final operations = await db.query('sync_operations');
      expect(operations, hasLength(1));
      final payload =
          jsonDecode(
                await OfflineVault.instance.openString(
                  operations.single['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      expect(payload['drawingJson'], contains('"text":"ABC"'));
      expect(payload['expectedRevision'], 'revision-base');
      expect(payload['mutationOrigin'], 'user_edit');
      expect(payload['writeId'], isNotEmpty);
      expect(payload['predecessorWriteIds'], hasLength(2));
      expect(await db.query('note_pages'), hasLength(1));
    },
  );
}
