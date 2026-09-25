import 'dart:convert';

import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const baseline = '2026-09-01T10:00:00.000Z';

Map<String, dynamic> dossier(String remoteTime, String firstName) => {
  'id': 'dossier-1',
  'createdAt': baseline,
  'updatedAt': remoteTime,
  'workspaceUpdatedAt': remoteTime,
  'status': 'IN_PROGRESS',
  'patient': {
    'id': 'patient-1',
    'firstName': firstName,
    'lastName': 'Test',
    'updatedAt': remoteTime,
  },
  'housing': {'updatedAt': remoteTime},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() async {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    ConnectivityService().dispose();
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    await ConnectivityService().initialize();
  });

  tearDown(() {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });

  for (final localWins in [true, false]) {
    test('latest edit wins a patient conflict (local=$localWins)', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      await repository.mergeRemoteDossierPayloads([
        dossier(baseline, 'Original'),
      ]);
      await repository.updatePatient('patient-1', {'first_name': 'Local'});
      final remoteTime = localWins
          ? '2026-09-02T10:00:00.000Z'
          : '2099-09-02T10:00:00.000Z';
      var patches = 0;
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/api/dossiers') {
              return http.Response(
                jsonEncode([dossier(remoteTime, 'Remote')]),
                200,
              );
            }
            expect(request.method, 'PATCH');
            patches++;
            if (patches == 1) {
              return http.Response(
                jsonEncode({
                  'error': 'SYNC_FIELD_CONFLICT',
                  'remoteUpdatedAt': remoteTime,
                  'remoteData': {'firstName': 'Remote'},
                }),
                409,
              );
            }
            return http.Response(
              jsonEncode({
                'data': {'updatedAt': '2100-01-01T00:00:00.000Z'},
              }),
              200,
            );
          }),
        ),
      );

      final first = await service.pushPendingChanges();
      expect(first.conflictCount, 0);
      final operation = (await db.query('sync_operations')).single;
      expect(operation['status'], localWins ? 'pending' : 'completed');
      expect(
        (await db.query('patients')).single['first_name'],
        localWins ? 'Local' : 'Remote',
      );
      if (localWins) {
        final second = await service.pushPendingChanges();
        expect(second.pushedOperations, 1);
        expect(patches, 2);
      } else {
        expect(patches, 1);
      }
    });
  }

  for (final localWins in [true, false]) {
    test('latest edit wins a visit note conflict (local=$localWins)', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final notes = NoteRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      const patientId = 'nocodb-beneficiaire-123';
      await notes.saveDrawingJson(
        patientId: patientId,
        tabKey: 'Contexte de vie',
        drawingJson: '{"local":true}',
        dossierId: 'dossier-1',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      const revision = '11111111-1111-4111-8111-111111111111';
      final remoteTime = localWins
          ? '2026-09-02T10:00:00.000Z'
          : '2099-09-02T10:00:00.000Z';
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'data': {
                    'notePages': [
                      {
                        'patientId': patientId,
                        'tabKey': 'Contexte de vie',
                        'pageNumber': 0,
                        'scopeType': 'visit_report',
                        'scopeId': 'dossier-1',
                        'drawingJson': '{"remote":true}',
                        'revision': revision,
                        'updatedAt': remoteTime,
                      },
                    ],
                  },
                }),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'error': 'NOTE_PAGE_REVISION_CONFLICT',
                'observed': {'revision': revision},
              }),
              409,
            );
          }),
        ),
      );

      final result = await service.pushPendingChanges();
      expect(result.conflictCount, 0);
      final note = (await db.query('note_pages')).single;
      if (localWins) {
        expect((await db.query('sync_operations')).single['status'], 'pending');
        expect(note['sync_state'], 'pendingSync');
      } else {
        expect(await db.query('sync_operations'), isEmpty);
        expect(note['sync_state'], 'synced');
        expect(
          await OfflineVault.instance.openString(
            note['drawing_json'] as String,
          ),
          '{"remote":true}',
        );
      }
    });
  }
}
