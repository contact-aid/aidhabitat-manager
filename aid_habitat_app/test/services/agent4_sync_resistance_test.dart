import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/services/app_config.dart';
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
      expect(dossier['remote_updated_at'], _baseVersion);
      expect(dossier['sync_state'], 'pendingSync');
      expect(operation['status'], 'pending');
      expect(queuedPayload['updates'], {'compteAnah': 'Second local value'});
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
