import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/independent_notes.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'two offline SQLite devices keep separate notes through push, pull and reopening',
    () async {
      const patient = 'nocodb-beneficiaire-fiction';
      const dossier = 'airtable:recFICTION';
      const keys = ['notes_rapides', 'Bénéficiaire-Notes'];
      final databases = <Database>[];
      final notes = <NoteRepository>[];
      final queues = <SyncRepository>[];
      for (var i = 0; i < 2; i++) {
        final db = await databaseFactoryFfi.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );
        databases.add(db);
        addTearDown(db.close);
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        notes.add(NoteRepository(database: local));
        queues.add(SyncRepository.forTesting(database: local));
      }
      final remote = {
        for (final key in keys)
          key: {
            'revision': '00000000-0000-4000-8000-000000000001',
            'drawing': jsonEncode({
              'version': 1,
              'text': 'Import fictif',
              'strokes': [],
              'noteTextInitialized': true,
            }),
          },
      };
      Future<void> pull(int device) async {
        for (final key in keys) {
          await notes[device].mergeRemoteNotePage(
            patientId: patient,
            dossierId: dossier,
            tabKey: key,
            pageNumber: 0,
            drawingJson: remote[key]!['drawing']!,
            revision: remote[key]!['revision'],
            updatedAt: '2099-01-01T00:00:00Z',
          );
        }
      }

      Future<void> edit(int device, String key, String value) =>
          notes[device].saveDrawingJson(
            patientId: patient,
            dossierId: key == keys[0] ? dossier : null,
            scopeType: key == keys[0] ? 'dossier_detail' : null,
            scopeId: key == keys[0] ? dossier : null,
            tabKey: key,
            drawingJson: jsonEncode({
              'version': 1,
              'text': value,
              'strokes': [
                {'fiction': device},
              ],
            }),
            mutationOrigin: SyncMutationOrigin.userEdit,
          );
      Future<void> push(int device) async {
        for (final operation
            in await queues[device].fetchRunnableOperations()) {
          expect(await queues[device].tryMarkRunning(operation), isTrue);
          final body = jsonDecode(operation.payloadJson) as Map;
          final key = body['tabKey'] as String;
          expect(body['expectedRevision'], remote[key]!['revision']);
          remote[key] = {
            'drawing': stampNoteTextInitialization(
              key,
              0,
              body['drawingJson'] as String,
            ),
            'revision': body['writeId'] as String,
          };
          expect(
            await queues[device].acknowledgeNotePageMutation(
              operation,
              revision: body['writeId'] as String,
              remotePath: 'synthetic/$key',
              remoteUrl: '',
            ),
            isTrue,
          );
        }
      }

      await pull(0);
      await pull(1);
      await edit(0, keys[0], 'Dossier web hors ligne');
      await edit(1, keys[1], 'Bénéficiaire iPad hors ligne');
      await pull(0); // cannot overwrite pending local edits
      await pull(1);
      await push(0);
      await push(1);
      await pull(0);
      await pull(1);
      for (var device = 0; device < 2; device++) {
        final reopened = NoteRepository(
          database: LocalDatabase.forTesting(databases[device]),
        );
        for (var keyIndex = 0; keyIndex < keys.length; keyIndex++) {
          final json =
              jsonDecode(
                    (await reopened.fetchDrawingJson(
                      patientId: patient,
                      tabKey: keys[keyIndex],
                    ))!,
                  )
                  as Map;
          expect(
            json['text'],
            keyIndex == 0
                ? 'Dossier web hors ligne'
                : 'Bénéficiaire iPad hors ligne',
          );
          expect(json['strokes'], [
            {'fiction': keyIndex},
          ]);
        }
        expect(await queues[device].countPendingOperations(), 0);
      }
      await edit(1, keys[1], '');
      await push(1);
      await pull(0);
      await pull(1);
      for (final repository in notes) {
        final json =
            jsonDecode(
                  (await repository.fetchDrawingJson(
                    patientId: patient,
                    tabKey: keys[1],
                  ))!,
                )
                as Map;
        expect(json['text'], '');
        expect(json['noteTextInitialized'], true);
        expect(json['strokes'], [
          {'fiction': 1},
        ]);
      }
    },
  );
}
