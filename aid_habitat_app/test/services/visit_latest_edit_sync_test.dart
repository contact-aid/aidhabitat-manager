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

  test(
    'collection conflict never auto-resolves or upgrades a legacy payload',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      await repository.mergeRemoteDossierPayloads([
        dossier(baseline, 'Original'),
      ]);
      await repository.updatePatient('patient-1', {'dependence_txt': 'Canne'});
      final row = (await db.query('sync_operations')).single;
      final legacy =
          jsonDecode(
                await OfflineVault.instance.openString(
                  row['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      (legacy['concurrency'] as Map).remove('collectionContract');
      await db.update('sync_operations', {
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode(legacy),
        ),
      });
      var writes = 0;
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            expect(
              request.method,
              'PATCH',
            ); // No automatic read/rebase after 409.
            expect(
              (jsonDecode(request.body)['concurrency'] as Map).containsKey(
                'collectionContract',
              ),
              isFalse,
            );
            writes++;
            return http.Response(
              jsonEncode({'error': 'COLLECTION_CLIENT_UPGRADE_REQUIRED'}),
              409,
            );
          }),
        ),
      );
      final result = await service.pushPendingChanges();
      expect(result.conflictCount, 1);
      expect(writes, 1);
      final after = (await db.query('sync_operations')).single;
      expect(after['status'], 'conflict');
      final retained = jsonDecode(
        await OfflineVault.instance.openString(after['payload_json'] as String),
      );
      expect(retained['updates'], legacy['updates']);
      expect(retained['concurrency'], legacy['concurrency']);
      expect(await db.query('sync_conflict_history'), isEmpty);
      expect((await db.query('patients')).single['dependence_txt'], 'Canne');
    },
  );

  for (final localWins in [true, false]) {
    test(
      'local patient edit wins regardless of server clock (older=$localWins)',
      () async {
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
        expect(operation['status'], 'pending');
        expect((await db.query('patients')).single['first_name'], 'Local');
        final second = await service.pushPendingChanges();
        expect(second.pushedOperations, 1);
        expect(patches, 2);
      },
    );
  }

  for (final savedConflict in [false, true]) {
    test(
      'zero-attempt patient conflict resumes automatically (stored=$savedConflict)',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(db.close);
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        final repository = DossierRepository(database: local);
        final queue = SyncRepository.forTesting(database: local);
        await repository.mergeRemoteDossierPayloads([
          dossier(baseline, 'Original'),
        ]);
        final opened = (await repository.fetchAllDossiers()).single;
        await db.update('patients', {'first_name': 'Server'});
        await repository.updatePatient('patient-1', {
          'first_name': 'Fresh edit',
        }, observedFields: opened.patientEditBaseline);
        final row = (await db.query('sync_operations')).single;
        expect(row['status'], 'conflict');
        expect(row['attempt_count'], 0);
        if (savedConflict) {
          final payload =
              jsonDecode(
                    await OfflineVault.instance.openString(
                      row['payload_json'] as String,
                    ),
                  )
                  as Map<String, dynamic>;
          payload['conflict'] = {
            'remote': {'error': 'SYNC_FIELD_CONFLICT'},
          };
          await db.update('sync_operations', {
            'payload_json': await OfflineVault.instance.sealString(
              jsonEncode(payload),
            ),
          });
        }
        var writes = 0;
        final service = NocodbSyncService(
          database: local,
          syncRepository: queue,
          apiClient: NocodbApiClient(
            client: MockClient((request) async {
              if (request.method == 'GET') {
                final remote = dossier('2026-10-22T10:00:00Z', 'Server');
                (remote['patient'] as Map)['email'] = 'retained@example.test';
                return http.Response(jsonEncode([remote]), 200);
              }
              writes++;
              final body = jsonDecode(request.body) as Map;
              expect(body['firstName'], 'Fresh edit');
              expect(body.containsKey('email'), isFalse);
              expect(body['concurrency']['baseValues']['firstName'], 'Server');
              return http.Response(
                jsonEncode({
                  'data': {'updatedAt': '2026-10-22T10:01:00Z'},
                }),
                200,
              );
            }),
          ),
        );
        final result = await service.pushPendingChanges();
        expect(result.conflictCount, 0);
        expect(result.pushedOperations, 1);
        expect(writes, 1);
        expect((await db.query('patients')).single['first_name'], 'Fresh edit');
        expect(
          (await db.query('sync_operations')).single['status'],
          'completed',
        );
        expect(
          await queue.countConflictingReportPrerequisites(
            dossierId: 'dossier-1',
            patientId: 'patient-1',
          ),
          0,
        );
        expect(
          await queue.countPendingReportPrerequisites(
            dossierId: 'dossier-1',
            patientId: 'patient-1',
          ),
          0,
        );
        expect(
          (await db.query('sync_conflict_history')).single['decision'],
          'auto_merge_latest',
        );
      },
    );
  }

  test(
    'stale beneficiary form merges the latest fund without undoing server health',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      final before = {
        'firstName': 'Original',
        'lastName': 'Test',
        'birthDate': '',
        'homeHelp': false,
        'caisseRetraitePrincipale': 'Avant',
      };
      final initial = dossier(baseline, 'Original');
      initial['patient'] = <String, dynamic>{
        ...(initial['patient'] as Map<String, dynamic>),
        'occupants': [before],
      };
      await repository.mergeRemoteDossierPayloads([initial]);
      final opened = (await repository.fetchAllDossiers()).single;
      final serverPerson = {...before, 'homeHelp': true};
      await db.update('patients', {
        'occupants_json': jsonEncode([serverPerson]),
      });
      await repository.updatePatient('patient-1', {
        'occupants_json': jsonEncode([
          {...before, 'caisseRetraitePrincipale': 'CNAV'},
        ]),
      }, observedFields: opened.patientEditBaseline);
      expect((await db.query('sync_operations')).single['status'], 'conflict');
      var writes = 0;
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              final remote = dossier('2026-10-22T10:00:00Z', 'Original');
              remote['patient'] = <String, dynamic>{
                ...(remote['patient'] as Map<String, dynamic>),
                'occupants': [serverPerson],
              };
              return http.Response(jsonEncode([remote]), 200);
            }
            writes++;
            final body = jsonDecode(request.body) as Map;
            expect(body['occupants'][0]['homeHelp'], true);
            expect(body['occupants'][0]['caisseRetraitePrincipale'], 'CNAV');
            expect(
              body['concurrency']['baseValues']['occupants'][0]['homeHelp'],
              true,
            );
            return http.Response(
              jsonEncode({
                'data': {'updatedAt': '2026-10-22T10:01:00Z'},
              }),
              200,
            );
          }),
        ),
      );
      expect((await service.pushPendingChanges()).pushedOperations, 1);
      expect(writes, 1);
      final saved = jsonDecode(
        (await db.query('patients')).single['occupants_json'] as String,
      );
      expect(saved[0]['homeHelp'], true);
      expect(saved[0]['caisseRetraitePrincipale'], 'CNAV');
    },
  );

  test(
    'an interrupted running patient save is replayed and releases report prerequisites',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      await repository.mergeRemoteDossierPayloads([
        dossier(baseline, 'Original'),
      ]);
      await repository.updatePatient('patient-1', {'first_name': 'Fresh'});
      final operation = (await queue.fetchRunnableOperations()).single;
      await queue.tryMarkRunning(operation);
      await db.update('sync_operations', {
        'updated_at': DateTime.now()
            .subtract(const Duration(minutes: 48))
            .toIso8601String(),
      });
      var writes = 0;
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            expect(request.method, 'PATCH');
            final body = jsonDecode(request.body) as Map;
            expect(body['firstName'], 'Fresh');
            expect(
              body['concurrency']['writeId'],
              jsonDecode(operation.payloadJson)['concurrency']['writeId'],
            );
            writes++;
            return http.Response(
              jsonEncode({
                'data': {'updatedAt': '2026-10-22T12:00:00Z'},
              }),
              200,
            );
          }),
        ),
      );
      expect((await service.pushPendingChanges()).pushedOperations, 1);
      expect(writes, 1);
      expect(
        await queue.countPendingReportPrerequisites(
          dossierId: 'dossier-1',
          patientId: 'patient-1',
        ),
        0,
      );
      expect((await db.query('sync_operations')).single['status'], 'completed');
    },
  );

  test('modern local collection wins a verified field conflict', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    final repository = DossierRepository(database: local);
    final initial = dossier(baseline, 'Original');
    (initial['patient'] as Map)['dependenceTxt'] = 'Avant';
    await repository.mergeRemoteDossierPayloads([initial]);
    await repository.updatePatient('patient-1', {'dependence_txt': 'Canne'});
    var patches = 0;
    final service = NocodbSyncService(
      database: local,
      syncRepository: SyncRepository.forTesting(database: local),
      apiClient: NocodbApiClient(
        client: MockClient((request) async {
          if (request.method == 'GET') {
            final remote = dossier('2099-01-01T00:00:00Z', 'Original');
            (remote['patient'] as Map)['dependenceTxt'] = 'Serveur';
            return http.Response(jsonEncode([remote]), 200);
          }
          patches++;
          final body = jsonDecode(request.body) as Map;
          expect(body['dependenceTxt'], 'Canne');
          expect(body['concurrency']['collectionContract'], 'collections-v2');
          if (patches == 1) {
            return http.Response(
              jsonEncode({'error': 'SYNC_FIELD_CONFLICT'}),
              409,
            );
          }
          expect(body['expectedUpdatedAt'], '2099-01-01T00:00:00Z');
          return http.Response(
            jsonEncode({
              'data': {'updatedAt': '2100-01-01T00:00:00Z'},
            }),
            200,
          );
        }),
      ),
    );
    expect((await service.pushPendingChanges()).conflictCount, 0);
    expect((await db.query('patients')).single['dependence_txt'], 'Canne');
    expect((await service.pushPendingChanges()).pushedOperations, 1);
    expect(patches, 2);
  });

  test(
    'local recommendations win with newer server time and keep drafts',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      await DossierRepository(
        database: local,
      ).mergeRemoteDossierPayloads([dossier(baseline, 'Original')]);
      const item = {'id': 'local', 'wikiItemId': 'wiki-1', 'note': 'Local'};
      const draft = {'id': 'draft', 'wikiItemId': '', 'note': 'Brouillon'};
      await db.insert('visit_recommendations', {
        'local_id': 'reco',
        'dossier_local_id': 'dossier-1',
        'items_json': jsonEncode([item, draft]),
        'sync_state': 'pendingSync',
        'updated_at': baseline,
      });
      await db.insert('sync_operations', {
        'id': 'recommendations',
        'entity_type': 'visit_recommendations',
        'entity_local_id': 'dossier-1',
        'operation_type': 'update',
        'status': 'pending',
        'attempt_count': 0,
        'created_at': baseline,
        'updated_at': baseline,
        'payload_json': jsonEncode({
          'dossierId': 'dossier-1',
          'envelope': {
            'protocolVersion': 1,
            'writeId': '11111111-1111-4111-8111-111111111111',
            'expectedRevision': null,
            'items': [item],
          },
        }),
      });
      const revision = '22222222-2222-4222-8222-222222222222';
      var puts = 0;
      final service = NocodbSyncService(
        database: local,
        syncRepository: SyncRepository.forTesting(database: local),
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'data': {
                    'snapshotExists': true,
                    'revision': revision,
                    'updatedAt': '2099-01-01T00:00:00Z',
                    'items': [
                      {
                        'id': 'remote',
                        'wikiItemId': 'wiki-1',
                        'note': 'Serveur',
                      },
                    ],
                  },
                }),
                200,
              );
            }
            puts++;
            final body = jsonDecode(request.body) as Map;
            expect(body['items'], [item]);
            if (puts == 1) {
              return http.Response(
                jsonEncode({
                  'error': 'VISIT_RECOMMENDATIONS_REVISION_CONFLICT',
                }),
                409,
              );
            }
            expect(body['expectedRevision'], revision);
            return http.Response(
              jsonEncode({
                'data': {'revision': revision},
              }),
              200,
            );
          }),
        ),
      );
      final first = await service.pushPendingChanges();
      expect(first.conflictCount, 0);
      expect((await db.query('sync_operations')).single['status'], 'pending');
      expect(
        jsonDecode(
          (await db.query('visit_recommendations')).single['items_json']
              as String,
        ),
        [item, draft],
      );
      expect((await service.pushPendingChanges()).pushedOperations, 1);
      expect(puts, 2);
    },
  );

  for (final scenario in [
    'older',
    'newer',
    'equal',
    'missing-time',
    'legacy',
    'legacy-deleted',
    'retry-existing-deleted',
    'edit-during-read',
    'session-change',
    'wrong-dossier',
    'missing-revision',
    'invalid-revision',
    'remote-read-fails',
    'retry-existing',
    'server-races',
    'missing-record',
  ]) {
    test('local note priority: $scenario', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      await db.insert('app_session', {
        'id': 1,
        'user_local_id': 'owner',
        'created_at': baseline,
        'updated_at': baseline,
      });
      final notes = NoteRepository(database: local);
      final queue = SyncRepository.forTesting(database: local);
      const patientId = 'nocodb-beneficiaire-123';
      const tab = 'Sanitaires-Notes';
      final deleted = scenario.endsWith('-deleted');
      final localDrawing = deleted
          ? '{"version":1,"deleted":true,"text":"","strokes":[]}'
          : '{"local":true}';
      await notes.saveDrawingJson(
        patientId: patientId,
        tabKey: tab,
        drawingJson: localDrawing,
        dossierId: 'dossier-1',
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
      const revision = '11111111-1111-4111-8111-111111111111';
      final localAt = (await db.query('note_pages')).single['updated_at'];
      var writes = 0;
      var failRecoveryRead = scenario.startsWith('retry-existing');
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            if (request.method == 'GET') {
              if (scenario == 'remote-read-fails' || failRecoveryRead) {
                return http.Response('{}', 500);
              }
              if (scenario == 'edit-during-read') {
                await notes.saveDrawingJson(
                  patientId: patientId,
                  tabKey: tab,
                  drawingJson: '{"latest":true}',
                  dossierId: 'dossier-1',
                  mutationOrigin: SyncMutationOrigin.userEdit,
                );
              }
              if (scenario == 'session-change') {
                AppConfig.setAppSessionToken('other-token');
              }
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'notePages': [
                      if (scenario != 'missing-record' &&
                          !(scenario.startsWith('legacy') &&
                              request.url.queryParameters['scopeId'] ==
                                  'dossier-1'))
                        {
                          'patientId': patientId,
                          'dossierId': scenario == 'wrong-dossier'
                              ? 'other'
                              : 'dossier-1',
                          'tabKey': tab,
                          'pageNumber': 0,
                          'scopeType': 'dossier_detail',
                          'scopeId': scenario.startsWith('legacy')
                              ? patientId
                              : 'dossier-1',
                          'drawingJson': '{"remote":true}',
                          if (scenario != 'missing-revision')
                            'revision': scenario == 'invalid-revision'
                                ? 'invalid'
                                : revision,
                          if (scenario != 'missing-time')
                            'updatedAt': scenario == 'equal'
                                ? localAt
                                : scenario == 'older'
                                ? baseline
                                : '2099-01-01T00:00:00Z',
                        },
                    ],
                  },
                }),
                200,
              );
            }
            writes++;
            final sent = jsonDecode(request.body) as Map;
            expect(sent['drawingJson'], localDrawing);
            if (writes > 1) {
              expect(sent['expectedRevision'], revision);
              expect(
                sent['scopeId'],
                scenario.startsWith('legacy') ? patientId : 'dossier-1',
              );
              if (scenario == 'server-races') {
                return http.Response(
                  jsonEncode({
                    'error': 'NOTE_PAGE_REVISION_CONFLICT',
                    'observed': {'revision': revision},
                  }),
                  409,
                );
              }
              return http.Response(
                jsonEncode({
                  'data': {
                    'notePage': {
                      'revision': '22222222-2222-4222-8222-222222222222',
                    },
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
      final succeeds = const {
        'older',
        'newer',
        'equal',
        'missing-time',
        'legacy',
        'legacy-deleted',
        'server-races',
      }.contains(scenario);
      expect(result.conflictCount, succeeds ? 0 : 1);
      final note = (await db.query('note_pages')).single;
      expect(
        await OfflineVault.instance.openString(note['drawing_json'] as String),
        scenario == 'edit-during-read' ? '{"latest":true}' : localDrawing,
      );
      expect(writes, 1);
      if (scenario.startsWith('retry-existing')) {
        // The first cycle retains a conflict after a transient read failure.
        failRecoveryRead = false;
        final retry = await service.pushPendingChanges();
        expect(retry.pushedOperations, 1);
        expect(retry.conflictCount, 0);
        expect(writes, 2);
      }
      if (succeeds) {
        expect((await db.query('sync_operations')).single['status'], 'pending');
        expect(note['sync_state'], 'pendingSync');
        final second = await service.pushPendingChanges();
        expect(second.pushedOperations, scenario == 'server-races' ? 0 : 1);
        expect(second.conflictCount, 0);
        expect(writes, 2);
        if (scenario == 'server-races') {
          expect(
            (await db.query('sync_operations')).single['status'],
            'pending',
          );
        }
      }
    });
  }
}
