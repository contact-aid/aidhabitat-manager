import 'dart:convert';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() {
    AppConfig.setApiBaseUrl('https://synthetic.invalid');
    AppConfig.setAppSessionToken('synthetic');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  for (final body in [
    '{}',
    '{"success":false,"data":{"notePages":[]}}',
    '{"success":true,"data":{"notePages":[null]}}',
    '{"success":true,"data":{"notePages":[{"patientId":"other","tabKey":"Plans","pageNumber":1}]}}',
  ]) {
    test('invalid or wrong-identity GET is never absence: $body', () async {
      final client = NocodbApiClient(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      await expectLater(
        client.fetchNotePage(patientId: 'p', tabKey: 'Plans', pageNumber: 1),
        throwsFormatException,
      );
    });
  }
  test(
    'verified empty GET is absence, unavailable configuration is not',
    () async {
      final client = NocodbApiClient(
        client: MockClient(
          (_) async =>
              http.Response('{"success":true,"data":{"notePages":[]}}', 200),
        ),
      );
      expect(
        await client.fetchNotePage(
          patientId: 'p',
          tabKey: 'Plans',
          pageNumber: 1,
        ),
        isNull,
      );
      AppConfig.setApiBaseUrl('');
      await expectLater(
        client.fetchNotePage(patientId: 'p', tabKey: 'Plans', pageNumber: 1),
        throwsStateError,
      );
    },
  );
  test(
    '500 and 413 keep correlation but never expose response content',
    () async {
      for (final status in [500, 413]) {
        const requestId = '00000000-0000-4000-8000-000000000001';
        final client = NocodbApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'error': status == 413
                    ? 'NOTE_PAGE_CONTENT_TOO_LARGE'
                    : 'private clinical text',
                'requestId': requestId,
                'drawingJson': 'private drawing',
              }),
              status,
            ),
          ),
        );
        try {
          await client.upsertNotePage(
            notePageId: 'n',
            patientId: 'p',
            tabKey: 'Plans',
            pageNumber: 1,
            drawingJson: '{}',
            expectedRevision: null,
            writeId: requestId,
          );
          fail('failure must not acknowledge the note');
        } catch (e) {
          expect(e.toString(), contains('requestId=$requestId'));
          expect(e.toString(), isNot(contains('private')));
          if (status == 500) {
            expect(e, isA<TransientRemoteException>());
          } else {
            expect(e.toString(), contains('NOTE_PAGE_CONTENT_TOO_LARGE'));
          }
        }
      }
    },
  );
  test(
    'two operations can be inspected without mutation or content export',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE sync_operations (id TEXT, entity_type TEXT, entity_local_id TEXT, operation_type TEXT, status TEXT, attempt_count INTEGER, created_at TEXT, updated_at TEXT, last_error TEXT, payload_json TEXT)',
      );
      await db.execute(
        'CREATE TABLE note_pages (local_id TEXT, drawing_json TEXT)',
      );
      const drawing = '{"text":"private clinical text","strokes":[{"x":100}]}';
      for (final id in ['conflict-op', 'pending-op']) {
        await db.insert('note_pages', {
          'local_id': id,
          'drawing_json': drawing,
        });
        await db.insert('sync_operations', {
          'id': id,
          'entity_type': 'note_page',
          'entity_local_id': id,
          'operation_type': 'upsert',
          'status': id == 'conflict-op' ? 'conflict' : 'pending',
          'attempt_count': 1,
          'created_at': '2026-10-05T10:00:00Z',
          'updated_at': '2026-10-05T11:00:00Z',
          'last_error':
              'Remote note sync failed (500) requestId=00000000-0000-4000-8000-000000000001 secret',
          'payload_json': jsonEncode({
            'drawingJson': drawing,
            'previewDataUrl': 'private preview',
            'patientLocalId': 'p',
            'tabKey': 'Plans',
            'pageNumber': 1,
            'writeId': 'w',
          }),
        });
      }
      final before = await db.query('sync_operations');
      final repo = SyncRepository.forTesting(databaseProvider: () async => db);
      for (final row in before) {
        final d = await repo.operationDiagnostic(row['id'] as String);
        expect(
          d!['drawingSha256'],
          sha256.convert(utf8.encode(drawing)).toString(),
        );
        expect(d['queuedMatchesLocal'], true);
        expect(d['httpStatus'], '500');
        final exported = jsonEncode(d);
        expect(exported, isNot(contains('private')));
        expect(exported, isNot(contains('secret')));
      }
      expect(await db.query('sync_operations'), before);
      expect(
        (await db.query(
          'note_pages',
        )).every((r) => r['drawing_json'] == drawing),
        true,
      );
      // A different account has no access to diagnostic payloads.
      await db.execute(
        'CREATE TABLE sync_operation_ownership (operation_id TEXT, owner_user_local_id TEXT, attribution_state TEXT)',
      );
      await db.execute(
        'CREATE TABLE app_session (id INTEGER, user_local_id TEXT)',
      );
      await db.insert('app_session', {'id': 1, 'user_local_id': 'other'});
      expect(
        await SyncRepository(
          databaseProvider: () async => db,
        ).operationDiagnostic('pending-op'),
        isNull,
      );
    },
  );
}
