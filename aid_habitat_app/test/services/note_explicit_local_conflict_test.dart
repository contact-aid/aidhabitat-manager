import 'dart:convert';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const patient = 'nocodb-beneficiaire-fiction';
const dossier = 'fiction-dossier';
const tab = 'Contexte de vie-Médical';
const id = 'note_${patient}_${tab}_3';
const op = 'sync_$id';
const revision = '00000000-0000-4000-8000-000000000031';
const oldRevision = '00000000-0000-4000-8000-000000000011';
const writeId = '00000000-0000-4000-8000-000000000012';
const drawing = '{"text":"copie locale é","strokes":[{"x":1}]}';
Map<String, dynamic> remote() => {
  'patientId': patient,
  'dossierId': dossier,
  'scopeType': 'dossier_detail',
  'scopeId': patient,
  'tabKey': tab,
  'subTabKey': '',
  'pageNumber': 3,
  'revision': revision,
  'drawingJson': 'different remote note',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SyncRepository sync;
  setUp(() async {
    AppConfig.setApiBaseUrl('https://synthetic.invalid');
    AppConfig.setAppSessionToken('owner-token');
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
      dossierId: dossier,
      tabKey: tab,
      pageNumber: 3,
      drawingJson: drawing,
      mutationOrigin: SyncMutationOrigin.userEdit,
    );
    sync = SyncRepository(databaseProvider: () async => db);
    await db.update('sync_operations', {
      'status': 'conflict',
      'payload_json': jsonEncode({
        'patientLocalId': patient,
        'dossierId': dossier,
        'tabKey': tab,
        'pageNumber': 3,
        'drawingJson': drawing,
        'expectedRevision': null,
        'writeId': writeId,
        'conflict': {
          'remote': {'error': 'NOTE_PAGE_IDENTITY_CONFLICT'},
        },
      }),
    });
    await db.update('note_pages', {'sync_state': 'conflict'});
  });
  tearDown(() async {
    await db.close();
    AppConfig.clearAppSessionToken();
    AppConfig.setApiBaseUrl('');
  });
  Future<Map<String, dynamic>> payload() async =>
      (jsonDecode(
                await OfflineVault.instance.openString(
                  (await db.query('sync_operations')).single['payload_json']
                      as String,
                ),
              )
              as Map)
          .cast<String, dynamic>();
  Future<void> alterPayload(Map<String, dynamic> changes) async =>
      db.update('sync_operations', {
        'payload_json': jsonEncode({...await payload(), ...changes}),
      });
  http.Response response(List<Map<String, dynamic>> pages) => http.Response(
    jsonEncode({
      'success': true,
      'data': {'notePages': pages},
    }),
    200,
  );

  for (final expected in [null, oldRevision]) {
    test(
      'explicit local choice uses fresh legacy revision when expected is $expected',
      () async {
        await alterPayload({'expectedRevision': expected});
        var gets = 0;
        var puts = 0;
        final client = NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'PUT') {
              puts++;
              final sent = jsonDecode(request.body) as Map;
              expect(sent['scopeId'], patient);
              expect(sent['expectedRevision'], revision);
              expect(sent['drawingJson'], drawing);
              expect(sent['writeId'], isNot(writeId));
              // Another writer raced after GET: never overwrite by rebasing again.
              return http.Response(
                '{"error":"NOTE_PAGE_REVISION_CONFLICT"}',
                409,
              );
            }
            gets++;
            expect(request.headers['X-App-Session'], 'owner-token');
            return response(
              request.url.queryParameters['scopeId'] == dossier
                  ? []
                  : [remote()],
            );
          }),
        );
        final before = (await db.query('note_pages')).single;
        expect(
          await DataService.forTesting(
            apiClient: client,
            syncRepository: sync,
          ).resolveNoteConflictKeepingLocal(op),
          isTrue,
        );
        expect(gets, 2);
        expect(puts, 0);
        final queued = await payload();
        expect(queued['scopeId'], patient);
        expect(queued['expectedRevision'], revision);
        expect(queued['drawingJson'], drawing);
        expect(queued.containsKey('conflict'), isFalse);
        final note = (await db.query('note_pages')).single;
        expect(note['drawing_json'], before['drawing_json']);
        expect(note['remote_revision'], revision);
        expect((await db.query('sync_operations')).single['status'], 'pending');
        await expectLater(
          client.upsertNotePage(
            notePageId: id,
            patientId: patient,
            tabKey: tab,
            pageNumber: 3,
            drawingJson: drawing,
            scopeId: queued['scopeId'] as String,
            expectedRevision: queued['expectedRevision'] as String,
            writeId: queued['writeId'] as String,
          ),
          throwsA(isA<ConflictException>()),
        );
        expect(puts, 1);
        expect((await payload())['expectedRevision'], revision);
      },
    );
  }
  for (final failure in [
    'ambiguous',
    'foreign-patient',
    'foreign-dossier',
    'foreign-scope',
    'foreign-subtab',
    'get-failure',
    'canonical-failure',
    'missing-revision',
    'invalid-revision',
    'session',
    'owner',
    'queue-edit',
    'drawing-edit',
    'local-text-edit',
    'no-legacy',
  ]) {
    test('$failure preserves queue and note without a resolution', () async {
      final beforeOps = await db.query('sync_operations');
      final beforeNotes = await db.query('note_pages');
      List<Map<String, Object?>>? editedOps;
      List<Map<String, Object?>>? editedNotes;
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          if (request.url.queryParameters['scopeId'] == dossier) {
            return failure == 'canonical-failure'
                ? http.Response('{}', 500)
                : response([]);
          }
          if (failure == 'get-failure') return http.Response('{}', 500);
          if (failure == 'session') AppConfig.setAppSessionToken('other-token');
          if (failure == 'owner') {
            await db.update('app_session', {'user_local_id': 'other'});
          }
          if (failure == 'queue-edit') {
            await alterPayload({
              'writeId': 'new-write',
              'previewDataUrl': 'new-preview',
            });
          }
          if (failure == 'drawing-edit') {
            await db.update('note_pages', {'drawing_json': 'new drawing'});
          }
          if (failure == 'local-text-edit') {
            await db.update('note_pages', {'text_content': 'new text'});
          }
          editedOps = await db.query('sync_operations');
          editedNotes = await db.query('note_pages');
          final value = remote();
          if (failure == 'foreign-patient') value['patientId'] = 'other';
          if (failure == 'foreign-dossier') value['dossierId'] = 'other';
          if (failure == 'foreign-scope') value['scopeType'] = 'other';
          if (failure == 'foreign-subtab') value['subTabKey'] = 'other';
          if (failure == 'missing-revision') value.remove('revision');
          if (failure == 'invalid-revision') {
            value['revision'] = 'not-a-revision';
          }
          return response(
            failure == 'no-legacy'
                ? []
                : failure == 'ambiguous'
                ? [value, value]
                : [value],
          );
        }),
      );
      expect(
        await DataService.forTesting(
          apiClient: client,
          syncRepository: sync,
        ).resolveNoteConflictKeepingLocal(op),
        isFalse,
      );
      expect(await db.query('sync_operations'), editedOps ?? beforeOps);
      expect(await db.query('note_pages'), editedNotes ?? beforeNotes);
    });
  }
  test(
    'another account cannot even start the remote resolution read',
    () async {
      await db.update('app_session', {'user_local_id': 'other'});
      final client = NocodbApiClient(
        client: MockClient((_) async {
          fail('No HTTP permitted');
        }),
      );
      expect(
        await DataService.forTesting(
          apiClient: client,
          syncRepository: sync,
        ).resolveNoteConflictKeepingLocal(op),
        isFalse,
      );
    },
  );
  test(
    'verified absence checks both scopes before existing missing-record create path',
    () async {
      await alterPayload({
        'conflict': {
          'remote': {'error': 'NOTE_PAGE_RECORD_MISSING'},
        },
      });
      final scopes = <String>[];
      final client = NocodbApiClient(
        client: MockClient((request) async {
          scopes.add(request.url.queryParameters['scopeId']!);
          return response([]);
        }),
      );
      expect(
        await DataService.forTesting(
          apiClient: client,
          syncRepository: sync,
        ).resolveNoteConflictKeepingLocal(op),
        isTrue,
      );
      expect(scopes, [dossier, patient]);
      expect((await payload())['expectedRevision'], isNull);
    },
  );
  test(
    'automatic legacy repair still refuses changed and absent expected revisions',
    () async {
      var gets = 0;
      final client = NocodbApiClient(
        client: MockClient((_) async {
          gets++;
          return response([remote()]);
        }),
      );
      for (final expected in [null, oldRevision]) {
        expect(
          await client.findLegacyNoteForRevision(
            patientId: patient,
            dossierId: dossier,
            scopeType: 'dossier_detail',
            tabKey: tab,
            pageNumber: 3,
            expectedRevision: expected,
            writeId: writeId,
          ),
          isNull,
        );
      }
      expect(gets, 1);
      expect(
        await sync.repairMissingNoteIdentity(
          op,
          writeId: writeId,
          remote: remote(),
        ),
        isFalse,
      );
      expect((await db.query('sync_operations')).single['status'], 'conflict');
    },
  );
  test(
    'session change after writes rolls back the complete transaction',
    () async {
      final snapshot = await sync.noteConflictDetails(
        op,
        forExplicitResolution: true,
      );
      final beforeOps = await db.query('sync_operations');
      final beforeNotes = await db.query('note_pages');
      var checks = 0;
      await expectLater(
        sync.resolveNoteConflictKeepingLocal(
          op,
          observedRevision: revision,
          observedRemote: remote(),
          explicitSnapshot: snapshot,
          checkSession: () {
            checks++;
            if (checks == 4) throw StateError('session changed');
          },
        ),
        throwsStateError,
      );
      expect(checks, 4);
      expect(await db.query('sync_operations'), beforeOps);
      expect(await db.query('note_pages'), beforeNotes);
    },
  );
}
