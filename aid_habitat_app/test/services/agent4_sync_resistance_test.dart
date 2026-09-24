import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _baseVersion = '2026-09-01T10:00:00.000Z';

Map<String, dynamic> _remoteDossier({
  String version = _baseVersion,
  String compteAnah = 'Initial ANAH',
  String natureAccompagnement = 'Initial nature',
}) => {
  'id': 'dossier-1',
  'updatedAt': version,
  'createdAt': _baseVersion,
  'workspaceUpdatedAt': version,
  'status': 'IN_PROGRESS',
  'compteAnah': compteAnah,
  'natureAccompagnement': natureAccompagnement,
  'patient': {
    'id': 'patient-1',
    'firstName': 'Test',
    'lastName': 'Synthetic',
    'phone': '0102030405',
    'updatedAt': version,
  },
  'housing': {
    'surface': 80,
    'updatedAt': version,
    'roomsBreakdown': {
      'basement': <String>[],
      'rdc': ['Cuisine'],
      'floor': <String>[],
      'secondFloor': <String>[],
      'thirdFloor': <String>[],
    },
  },
};

class _Device {
  _Device(this.db, this.local)
    : dossiers = DossierRepository(database: local),
      queue = SyncRepository.forTesting(database: local);

  final Database db;
  final LocalDatabase local;
  final DossierRepository dossiers;
  final SyncRepository queue;
}

Future<_Device> _openDevice() async {
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  final local = LocalDatabase.forTesting(db);
  await local.createSchemaForTesting();
  return _Device(db, local);
}

Future<void> _setConnectivity(List<String> values) async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  ConnectivityService().dispose();
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (_) async => values,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    (_) async => null,
  );
  await ConnectivityService().initialize();
}

class _GuardedDossierServer {
  var versionCounter = 1;
  var version = _baseVersion;
  final values = <String, dynamic>{
    'compteAnah': 'Initial ANAH',
    'natureAccompagnement': 'Initial nature',
  };
  final seenWriteIds = <String>[];

  String _nextVersion() {
    versionCounter++;
    return '2026-09-0${versionCounter}T10:00:00.000Z';
  }

  Future<http.Response> handle(http.Request request) async {
    expect(request.method, 'PATCH');
    expect(request.url.path, '/api/dossiers/dossier-1');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final guard = (body['concurrency'] as Map).cast<String, dynamic>();
    final updates = Map<String, dynamic>.from(body)
      ..remove('concurrency')
      ..remove('expectedUpdatedAt');
    final base = (guard['baseValues'] as Map).cast<String, dynamic>();
    seenWriteIds.add(guard['writeId'] as String);

    if (guard['expectedUpdatedAt'] != version) {
      final conflicts = updates.keys.where((key) {
        return !base.containsKey(key) ||
            (values[key] != base[key] && values[key] != updates[key]);
      }).toList();
      if (conflicts.isNotEmpty) {
        return http.Response(
          jsonEncode({
            'error': 'synthetic conflict',
            'remoteUpdatedAt': version,
            'remoteData': Map<String, dynamic>.from(values),
            'conflictingFields': conflicts,
          }),
          409,
        );
      }
    }

    values.addAll(updates);
    version = _nextVersion();
    return http.Response(
      jsonEncode({
        'success': true,
        'data': {'updatedAt': version},
      }),
      200,
    );
  }

  Map<String, dynamic> snapshot() => _remoteDossier(
    version: version,
    compteAnah: values['compteAnah'] as String,
    natureAccompagnement: values['natureAccompagnement'] as String,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUp(() async {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
    await _setConnectivity(['wifi']);
  });

  tearDown(() {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });

  for (final editDuringRequest in [false, true]) {
    test(
      'birth date then invalidity sync without self conflict (overlap=$editDuringRequest)',
      () async {
        final device = await _openDevice();
        addTearDown(device.db.close);
        await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
        final entered = Completer<void>();
        final release = Completer<void>();
        var version = _baseVersion;
        var requests = 0;
        final service = NocodbSyncService(
          database: device.local,
          syncRepository: device.queue,
          apiClient: NocodbApiClient(
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              requests++;
              if (body['expectedUpdatedAt'] != version) {
                return http.Response(
                  jsonEncode({'conflict': true, 'remoteUpdatedAt': version}),
                  409,
                );
              }
              if (requests == 1) {
                entered.complete();
                await release.future;
              } else {
                expect(body['invalidity'], true);
              }
              version = '2026-09-02T10:0$requests:00.000Z';
              return http.Response(
                jsonEncode({
                  'data': {'updatedAt': version},
                }),
                200,
              );
            }),
          ),
        );
        await device.dossiers.updatePatient('patient-1', {
          'birth_date': '1957-09-11',
        });
        final first = service.pushPendingChanges();
        await entered.future;
        if (editDuringRequest) {
          await device.dossiers.updatePatient('patient-1', {'invalidity': 1});
        }
        release.complete();
        await first;
        if (!editDuringRequest) {
          await device.dossiers.updatePatient('patient-1', {'invalidity': 1});
        }
        final result = await service.pushPendingChanges();
        expect(result.conflictCount, 0);
        expect(result.failedOperations, 0);
        expect(result.pushedOperations, 1);
        expect(requests, 2);
        final patient = (await device.db.query('patients')).single;
        expect(patient['birth_date'], '1957-09-11');
        expect(patient['invalidity'], 1);
        expect(patient['sync_state'], 'synced');
      },
    );
  }

  for (final missingVersion in [false, true]) {
    test(
      'lost ACK then newer edit confirms predecessor first (missingVersion=$missingVersion)',
      () async {
        final device = await _openDevice();
        addTearDown(device.db.close);
        await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
        final entered = Completer<void>();
        final release = Completer<void>();
        var calls = 0;
        String? firstWriteId;
        final service = NocodbSyncService(
          database: device.local,
          syncRepository: device.queue,
          apiClient: NocodbApiClient(
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map;
              calls++;
              if (calls == 1) {
                firstWriteId = body['concurrency']['writeId'] as String;
                entered.complete();
                await release.future;
                if (missingVersion) {
                  return http.Response('{"success":true,"data":{}}', 200);
                }
                throw http.ClientException('response lost after commit');
              }
              if (calls == 2) {
                expect(body['concurrency']['writeId'], firstWriteId);
                expect(body.containsKey('invalidity'), isFalse);
              } else {
                expect(body['invalidity'], true);
                expect(body['expectedUpdatedAt'], '2026-09-02T10:01:00.000Z');
              }
              return http.Response(
                jsonEncode({
                  'data': {
                    'updatedAt': calls == 2
                        ? '2026-09-02T10:01:00.000Z'
                        : '2026-09-02T10:02:00.000Z',
                  },
                }),
                200,
              );
            }),
          ),
        );
        await device.dossiers.updatePatient('patient-1', {
          'birth_date': '1957-09-11',
        });
        final sending = service.pushPendingChanges();
        await entered.future;
        await device.dossiers.updatePatient('patient-1', {'invalidity': 1});
        release.complete();
        expect((await sending).conflictCount, 0);
        expect((await service.pushPendingChanges()).conflictCount, 0);
        final result = await service.pushPendingChanges();
        expect(result.conflictCount, 0);
        expect(result.pushedOperations, 1);
        expect(calls, 3);
        final patient = (await device.db.query('patients')).single;
        expect(patient['invalidity'], 1);
        expect(patient['birth_date'], '1957-09-11');
        expect(patient['sync_state'], 'synced');
      },
    );
  }

  test(
    'a newer edit cannot be acknowledged by an older in-flight reply',
    () async {
      final device = await _openDevice();
      addTearDown(device.db.close);
      await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      await device.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'First local value',
      });

      final requestEntered = Completer<void>();
      final releaseReply = Completer<void>();
      final client = NocodbApiClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['compteAnah'], 'First local value');
          requestEntered.complete();
          await releaseReply.future;
          return http.Response(
            '{"data":{"updatedAt":"2026-09-02T10:00:00.000Z"}}',
            200,
          );
        }),
      );

      final push = NocodbSyncService(
        apiClient: client,
        syncRepository: device.queue,
      ).pushPendingChanges();
      await requestEntered.future;
      await device.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Second local value',
      });
      releaseReply.complete();
      final result = await push;

      final dossier = (await device.db.query('dossiers')).single;
      final operation = (await device.db.query('sync_operations')).single;
      final queuedPayload =
          jsonDecode(
                await OfflineVault.instance.openString(
                  operation['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      expect(result.pushedOperations, 0);
      expect(result.deferredOperations, 1);
      expect(dossier['compte_anah'], 'Second local value');
      expect(dossier['remote_updated_at'], '2026-09-02T10:00:00.000Z');
      expect(dossier['sync_state'], 'pendingSync');
      expect(operation['status'], 'pending');
      expect(queuedPayload['updates'], {'compteAnah': 'Second local value'});
      expect(
        queuedPayload['concurrency']['expectedUpdatedAt'],
        '2026-09-02T10:00:00.000Z',
      );
      expect(queuedPayload['concurrency']['baseValues'], {
        'compteAnah': 'First local value',
      });
      final secondPush = await NocodbSyncService(
        syncRepository: device.queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['expectedUpdatedAt'], '2026-09-02T10:00:00.000Z');
            expect(body['compteAnah'], 'Second local value');
            return http.Response(
              '{"data":{"updatedAt":"2026-09-02T10:01:00.000Z"}}',
              200,
            );
          }),
        ),
      ).pushPendingChanges();
      expect(secondPush.conflictCount, 0);
      expect(secondPush.pushedOperations, 1);
    },
  );

  test(
    'a lost success reply is retried after restart with the same write id',
    () async {
      final device = await _openDevice();
      addTearDown(device.db.close);
      await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      await device.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Persisted exactly once',
      });

      final appliedWriteIds = <String>{};
      final requests = <String>[];
      var loseFirstReply = true;
      final client = NocodbApiClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final guard = (body['concurrency'] as Map).cast<String, dynamic>();
          final writeId = guard['writeId'] as String;
          requests.add(writeId);
          appliedWriteIds.add(writeId);
          if (loseFirstReply) {
            loseFirstReply = false;
            throw http.ClientException('synthetic reply lost after commit');
          }
          return http.Response(
            '{"data":{"updatedAt":"2026-09-02T10:00:00.000Z"}}',
            200,
          );
        }),
      );

      final first = await NocodbSyncService(
        apiClient: client,
        syncRepository: device.queue,
      ).pushPendingChanges();
      expect(first.deferredOperations, 1);
      expect(
        (await device.db.query('sync_operations')).single['status'],
        'pending',
      );
      expect(
        (await device.db.query('dossiers')).single['sync_state'],
        'pendingSync',
      );

      await device.db.update('sync_operations', {'updated_at': _baseVersion});
      final restartedQueue = SyncRepository.forTesting(database: device.local);
      final restartedService = NocodbSyncService(
        apiClient: client,
        syncRepository: restartedQueue,
      );
      final second = await restartedService.pushPendingChanges();

      expect(second.pushedOperations, 1);
      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expect(appliedWriteIds, hasLength(1));
      expect(
        (await device.db.query('sync_operations')).single['status'],
        'completed',
      );
      final row = (await device.db.query('dossiers')).single;
      expect(row['compte_anah'], 'Persisted exactly once');
      expect(row['remote_updated_at'], '2026-09-02T10:00:00.000Z');
      expect(row['sync_state'], 'synced');
    },
  );

  test(
    'offline detection performs no HTTP write and restart resumes the queue',
    () async {
      final device = await _openDevice();
      addTearDown(device.db.close);
      await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      await device.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Queued offline',
      });
      var requests = 0;
      final client = NocodbApiClient(
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '{"data":{"updatedAt":"2026-09-02T10:00:00.000Z"}}',
            200,
          );
        }),
      );

      await _setConnectivity(['none']);
      await NocodbSyncService(
        apiClient: client,
        syncRepository: device.queue,
      ).pushPendingChanges();
      expect(requests, 0);
      expect(
        (await device.db.query('sync_operations')).single['status'],
        'pending',
      );
      expect(
        (await device.db.query('dossiers')).single['compte_anah'],
        'Queued offline',
      );

      await _setConnectivity(['wifi']);
      final result = await NocodbSyncService(
        apiClient: client,
        syncRepository: SyncRepository.forTesting(database: device.local),
      ).pushPendingChanges();
      expect(result.pushedOperations, 1);
      expect(requests, 1);
      expect(
        (await device.db.query('sync_operations')).single['status'],
        'completed',
      );
      expect(
        (await device.db.query('dossiers')).single['sync_state'],
        'synced',
      );
    },
  );

  test('a process restart recovers an operation left running', () async {
    final device = await _openDevice();
    addTearDown(device.db.close);
    await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
    await device.dossiers.updateDossierFields('dossier-1', {
      'compte_anah': 'Interrupted before acknowledgement',
    });
    final claimed = (await device.queue.fetchRunnableOperations()).single;
    expect(await device.queue.tryMarkRunning(claimed), isTrue);
    expect(
      (await device.db.query('sync_operations')).single['status'],
      'running',
    );

    final restartedQueue = SyncRepository.forTesting(database: device.local);
    final recovered = await restartedQueue.purgeStalePendingOperations(
      interruptedBefore: DateTime.now().add(const Duration(seconds: 1)),
    );
    expect(recovered, 1);
    expect(
      (await device.db.query('sync_operations')).single['status'],
      'pending',
    );

    final result = await NocodbSyncService(
      apiClient: NocodbApiClient(
        client: MockClient(
          (_) async => http.Response(
            '{"data":{"updatedAt":"2026-09-02T10:00:00.000Z"}}',
            200,
          ),
        ),
      ),
      syncRepository: restartedQueue,
    ).pushPendingChanges();
    expect(result.pushedOperations, 1);
    expect(
      (await device.db.query('sync_operations')).single['status'],
      'completed',
    );
    expect((await device.db.query('dossiers')).single['sync_state'], 'synced');
  });

  test('two devices editing different fields are both acknowledged', () async {
    final first = await _openDevice();
    await first.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
    await first.dossiers.updateDossierFields('dossier-1', {
      'compte_anah': 'Changed by device A',
    });
    final server = _GuardedDossierServer();
    final client = NocodbApiClient(client: MockClient(server.handle));

    final resultA = await NocodbSyncService(
      apiClient: client,
      syncRepository: first.queue,
    ).pushPendingChanges();
    expect((await first.db.query('dossiers')).single['sync_state'], 'synced');
    await first.db.close();

    // Device B reconnects later with the original server snapshot.
    final second = await _openDevice();
    addTearDown(second.db.close);
    await second.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
    await second.dossiers.updateDossierFields('dossier-1', {
      'nature_accompagnement': 'Changed by device B',
    });
    final resultB = await NocodbSyncService(
      apiClient: client,
      syncRepository: second.queue,
    ).pushPendingChanges();

    expect(resultA.pushedOperations, 1);
    expect(resultB.pushedOperations, 1);
    expect(server.values, {
      'compteAnah': 'Changed by device A',
      'natureAccompagnement': 'Changed by device B',
    });
    expect((await second.db.query('dossiers')).single['sync_state'], 'synced');
  });

  test(
    'fictitious levels sync, reopen, then sync a new WC and bathroom',
    () async {
      final device = await _openDevice();
      addTearDown(device.db.close);
      await device.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      var serverVersion = _baseVersion;
      var serverRooms = <String, dynamic>{
        'basement': <String>[],
        'rdc': ['Cuisine'],
        'floor': <String>[],
        'secondFloor': <String>[],
        'thirdFloor': <String>[],
      };
      var writes = 0;
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'PATCH');
          expect(request.url.path, '/api/logements/by-beneficiary/patient-1');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final guard = (body['concurrency'] as Map).cast<String, dynamic>();
          expect(body['expectedUpdatedAt'], serverVersion);
          expect(guard['baseValues']['roomsBreakdown'], serverRooms);
          serverRooms = (body['roomsBreakdown'] as Map).cast<String, dynamic>();
          writes++;
          serverVersion = '2026-09-0${writes + 1}T10:00:00.000Z';
          return http.Response(
            jsonEncode({
              'data': {'id': 'housing-1', 'updatedAt': serverVersion},
            }),
            200,
          );
        }),
      );
      await device.dossiers.updateHousing('dossier-1', {
        'rdc': true,
        'rdc_rooms_json': jsonEncode(['Cuisine', 'WC']),
      });
      final first = await NocodbSyncService(
        database: device.local,
        syncRepository: device.queue,
        apiClient: client,
      ).pushPendingChanges();
      expect(first.conflictCount, 0);
      expect(first.pushedOperations, 1);

      // Reopening reads the acknowledged SQLite row. A replica pull is guarded
      // briefly after the write, so it cannot replace this newer local state.
      final reopened = DossierRepository(database: device.local);
      expect(
        jsonDecode(
          (await reopened.fetchHousingRaw('dossier-1'))!['rdc_rooms_json']
              as String,
        ),
        ['Cuisine', 'WC'],
      );
      await reopened.updateHousing('dossier-1', {
        'rdc_rooms_json': jsonEncode(['Cuisine', 'WC', 'Salle de bain']),
      });
      final second = await NocodbSyncService(
        database: device.local,
        syncRepository: device.queue,
        apiClient: client,
      ).pushPendingChanges();
      expect(second.conflictCount, 0);
      expect(second.pushedOperations, 1);
      expect(writes, 2);
      expect(serverRooms['rdc'], ['Cuisine', 'WC', 'Salle de bain']);
      expect(
        (await reopened.fetchHousingRaw('dossier-1'))!['sync_state'],
        'synced',
      );
    },
  );

  test('fictitious autonomy sync, reopen, then medical context sync', () async {
    const firstRevision = '11111111-1111-4111-8111-111111111111';
    const secondRevision = '22222222-2222-4222-8222-222222222222';
    const thirdRevision = '33333333-3333-4333-8333-333333333333';
    final device = await _openDevice();
    addTearDown(device.db.close);
    final remote = _remoteDossier()
      ..['medicalContext'] = const MedicalContext().toJson()
      ..['autonomy'] = const AutonomyData().toJson()
      ..['contextServerReference'] = {
        'recordId': 501,
        'revision': firstRevision,
        'updatedAt': _baseVersion,
      };
    await device.dossiers.mergeRemoteDossierPayloads([remote]);
    var expectedRevision = firstRevision;
    var writes = 0;
    final client = NocodbApiClient(
      client: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/contextes/dossier-1');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final guard = (body['concurrency'] as Map).cast<String, dynamic>();
        expect(guard['reference']['revision'], expectedRevision);
        final updates = (body['updates'] as Map).cast<String, dynamic>();
        writes++;
        if (writes == 1) {
          expect((updates['autonomy'] as Map)['done'], isTrue);
          expect(updates.containsKey('medicalContext'), isFalse);
          expectedRevision = secondRevision;
        } else {
          expect((updates['medicalContext'] as Map)['pathology'], 'fiction');
          expect(updates.containsKey('autonomy'), isFalse);
          expectedRevision = thirdRevision;
        }
        return http.Response(
          jsonEncode({
            'data': {
              'serverReference': {
                'recordId': 501,
                'revision': expectedRevision,
                'updatedAt': '2026-09-0${writes + 1}T10:00:00.000Z',
              },
            },
          }),
          200,
        );
      }),
    );
    await device.dossiers.upsertContexteDeVie(
      'dossier-1',
      'patient-1',
      autonomy: const AutonomyData(done: true),
    );
    final first = await NocodbSyncService(
      database: device.local,
      syncRepository: device.queue,
      apiClient: client,
    ).pushPendingChanges();
    expect(first.conflictCount, 0);
    expect(first.pushedOperations, 1);

    final reopened = DossierRepository(database: device.local);
    expect(
      (await reopened.fetchContexteDeVie('dossier-1'))!['autonomy']['done'],
      isTrue,
    );
    await reopened.upsertContexteDeVie(
      'dossier-1',
      'patient-1',
      medicalContext: const MedicalContext(pathology: 'fiction'),
    );
    final second = await NocodbSyncService(
      database: device.local,
      syncRepository: device.queue,
      apiClient: client,
    ).pushPendingChanges();
    expect(second.conflictCount, 0);
    expect(second.pushedOperations, 1);
    expect(writes, 2);
    expect(
      (await device.db.query('contexte_de_vie')).single['sync_state'],
      'synced',
    );
  });

  test(
    'fictitious context take-server decision permits a new guarded sync',
    () async {
      const firstRevision = '11111111-1111-4111-8111-111111111111';
      const secondRevision = '22222222-2222-4222-8222-222222222222';
      const thirdRevision = '33333333-3333-4333-8333-333333333333';
      final device = await _openDevice();
      addTearDown(device.db.close);
      final remote = _remoteDossier()
        ..['medicalContext'] = const MedicalContext().toJson()
        ..['autonomy'] = const AutonomyData().toJson()
        ..['contextServerReference'] = {
          'recordId': 501,
          'revision': firstRevision,
          'updatedAt': _baseVersion,
        };
      await device.dossiers.mergeRemoteDossierPayloads([remote]);
      await device.dossiers.upsertContexteDeVie(
        'dossier-1',
        'patient-1',
        autonomy: const AutonomyData(done: true),
      );
      var writes = 0;
      final client = NocodbApiClient(
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final guard = (body['concurrency'] as Map).cast<String, dynamic>();
          writes++;
          if (writes == 1) {
            expect(guard['reference']['revision'], firstRevision);
            return http.Response(
              jsonEncode({
                'error': 'CONTEXT_REFERENCE_CONFLICT',
                'remoteUpdatedAt': '2026-09-02T10:00:00.000Z',
              }),
              409,
            );
          }
          expect(guard['reference']['revision'], secondRevision);
          expect((body['updates']['autonomy'] as Map)['done'], isTrue);
          return http.Response(
            jsonEncode({
              'data': {
                'serverReference': {
                  'recordId': 501,
                  'revision': thirdRevision,
                  'updatedAt': '2026-09-03T10:00:00.000Z',
                },
              },
            }),
            200,
          );
        }),
      );
      final first = await NocodbSyncService(
        database: device.local,
        syncRepository: device.queue,
        apiClient: client,
      ).pushPendingChanges();
      expect(first.conflictCount, 1);
      expect(
        (await device.db.query('contexte_de_vie')).single['sync_state'],
        'conflict',
      );

      final review = (await device.dossiers.reviewSecondaryConflicts(
        'dossier-1',
        {
          'contexte_de_vie': {
            'dossierId': 'dossier-1',
            'serverReference': {
              'recordId': 501,
              'revision': secondRevision,
              'updatedAt': '2026-09-02T10:00:00.000Z',
            },
            'medicalContext': const MedicalContext().toJson(),
            'autonomy': const AutonomyData().toJson(),
          },
        },
      )).single;
      await device.dossiers.resolveReviewedConflict(review, keepLocal: false);
      final reopened = DossierRepository(database: device.local);
      expect(
        (await reopened.fetchContexteDeVie('dossier-1'))!['autonomy']['done'],
        isFalse,
      );
      await reopened.upsertContexteDeVie(
        'dossier-1',
        'patient-1',
        autonomy: const AutonomyData(done: true),
      );
      final second = await NocodbSyncService(
        database: device.local,
        syncRepository: device.queue,
        apiClient: client,
      ).pushPendingChanges();
      expect(second.conflictCount, 0);
      expect(second.pushedOperations, 1);
      expect(writes, 2);
      expect(
        (await device.db.query('contexte_de_vie')).single['sync_state'],
        'synced',
      );
      expect((await device.db.query('sync_conflict_history')).length, 1);
    },
  );

  test(
    'same-field conflict stays local and an obsolete comparison cannot win',
    () async {
      final first = await _openDevice();
      await first.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      await first.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Device A',
      });
      final server = _GuardedDossierServer();
      final client = NocodbApiClient(client: MockClient(server.handle));

      await NocodbSyncService(
        apiClient: client,
        syncRepository: first.queue,
      ).pushPendingChanges();
      await first.db.close();

      // Device B still has the original snapshot and edits the same field.
      final second = await _openDevice();
      addTearDown(second.db.close);
      await second.dossiers.mergeRemoteDossierPayloads([_remoteDossier()]);
      await second.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Device B before comparison',
      });
      final conflict = await NocodbSyncService(
        apiClient: client,
        syncRepository: second.queue,
      ).pushPendingChanges();
      expect(conflict.conflictCount, 1);
      expect(
        (await second.db.query('dossiers')).single['sync_state'],
        'conflict',
      );
      expect(
        (await second.db.query('dossiers')).single['compte_anah'],
        'Device B before comparison',
      );

      final review = (await second.dossiers.reviewConflicts(
        'dossier-1',
        server.snapshot(),
      )).single;
      await second.dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'Device B after comparison',
      });
      await expectLater(
        second.dossiers.resolveReviewedConflict(review, keepLocal: false),
        throwsA(isA<StateError>()),
      );

      final row = (await second.db.query('dossiers')).single;
      final op = (await second.db.query('sync_operations')).single;
      expect(row['compte_anah'], 'Device B after comparison');
      expect(row['sync_state'], 'conflict');
      expect(op['status'], 'conflict');
      expect(server.values['compteAnah'], 'Device A');
    },
  );
}
