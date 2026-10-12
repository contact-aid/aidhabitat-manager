import 'dart:convert';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_backup_service.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  const patient = 'nocodb-beneficiaire-fiction';
  const op = 'sync_note_${patient}_Plans_1';
  const drawing = '{"text":"dessin synthétique éè","strokes":[{"x":1}]}';
  setUp(() async {
    AppConfig.setApiBaseUrl('https://synthetic.invalid');
    AppConfig.setAppSessionToken('secret-not-to-export');
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    await db.insert('app_session', {
      'id': 1,
      'user_local_id': 'owner',
      'created_at': '2026-10-05',
      'updated_at': '2026-10-05',
    });
    await NoteRepository(database: local).saveDrawingJson(
      patientId: patient,
      dossierId: 'fictive',
      tabKey: 'Plans',
      pageNumber: 1,
      drawingJson: drawing,
      mutationOrigin: SyncMutationOrigin.userEdit,
    );
    await db.update('sync_operations', {
      'status': 'conflict',
      'attempt_count': 4,
      'last_error': 'NOTE_PAGE_REVISION_CONFLICT',
    });
  });
  tearDown(() async {
    await db.close();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  for (final scenario in [
    'success',
    'wrong-receipt',
    'tampered-content',
    'unavailable',
    'session-change',
  ]) {
    test('backup $scenario never mutates the note or sync queue', () async {
      final beforeOps = await db.query('sync_operations');
      final beforeNotes = await db.query('note_pages');
      var posted = '';
      var getCount = 0;
      Map<String, dynamic> receipt() => {
        'backupId': 'synthetic-backup',
        'sha256': sha256.convert(utf8.encode(posted)).toString(),
        'bytes': utf8.encode(posted).length,
        'storedVerified': true,
        'createdAt': '2026-10-05',
        'source': 'local-operation',
      };
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.headers['X-App-Session'], 'secret-not-to-export');
          if (request.method == 'POST') {
            expect(request.url.path, '/api/note-backups');
            final body = jsonDecode(request.body) as Map;
            posted = body['snapshotJson'] as String;
            expect(posted, isNot(contains('secret-not-to-export')));
            expect(body['patientId'], patient);
            final snapshot = jsonDecode(posted) as Map;
            expect(snapshot['payload']['drawingJson'], drawing);
            expect(snapshot['localNote']['drawingJson'], drawing);
            expect(snapshot['status'], 'conflict');
            if (scenario == 'session-change') {
              AppConfig.setAppSessionToken('other');
            }
            if (scenario == 'unavailable') {
              return http.Response('{"error":"private remote content"}', 503);
            }
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'receipt': {
                    ...receipt(),
                    if (scenario == 'wrong-receipt') 'sha256': 'wrong',
                  },
                },
              }),
              201,
            );
          }
          getCount++;
          expect(
            request.url.path,
            '/api/note-backups/synthetic-backup/content',
          );
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'patientId': patient,
                'snapshotJson': scenario == 'tampered-content'
                    ? '$posted '
                    : posted,
                'receipt': receipt(),
              },
            }),
            200,
          );
        }),
      );
      final service = NoteBackupService(
        databaseProvider: () async => db,
        apiClient: client,
      );
      if (scenario == 'success') {
        final result = await service.backupOperation(op);
        expect(result['storedVerified'], true);
        expect(getCount, 1);
      } else {
        await expectLater(
          service.backupOperation(op),
          throwsA(anyOf(isA<Exception>(), isA<StateError>())),
        );
      }
      expect(await db.query('sync_operations'), beforeOps);
      expect(await db.query('note_pages'), beforeNotes);
    });
  }
  test(
    'snapshot includes distinct local and queued versions; other account is refused',
    () async {
      await db.update('note_pages', {'drawing_json': '{"strokes":[2]}'});
      final service = NoteBackupService(databaseProvider: () async => db);
      final before = await db.query('sync_operations');
      final snapshot = await service.readSnapshot(op);
      expect((snapshot['payload'] as Map)['drawingJson'], drawing);
      expect((snapshot['localNote'] as Map)['drawingJson'], '{"strokes":[2]}');
      expect(await db.query('sync_operations'), before);
      await db.update('app_session', {'user_local_id': 'other'});
      await expectLater(service.readSnapshot(op), throwsStateError);
    },
  );
}
