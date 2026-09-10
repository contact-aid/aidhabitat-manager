import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _tables = [
  'mesures_anthropometriques',
  'observations_synthese',
  'diagnostic_sanitaires',
];
const _old = '2026-09-01T10:00:00Z';
const _new = '2026-09-10T10:00:00Z';
const _guard = {
  'version': 1,
  'writeId': '12345678-1234-4234-8234-123456789012',
  'expectedUpdatedAt': _old,
  'baseValues': <String, dynamic>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  late SyncRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = SyncRepository.forTesting(database: local);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    AppConfig.setApiBaseUrl('https://fake.test');
    AppConfig.setAppSessionToken('synthetic-token');
    await ConnectivityService().initialize();
  });
  tearDown(() async {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
    await db.close();
  });

  Future<SyncOperation> seed(
    String table, {
    String status = 'running',
    String dossierId = 'local_dossier',
    Map<String, dynamic>? payload,
  }) async {
    await db.insert(table, {
      'local_id': '$table-row',
      'dossier_local_id': dossierId,
      'remote_updated_at': _old,
      'updated_at': _old,
      'sync_state': 'pendingSync',
    });
    final encoded = jsonEncode(
      payload ??
          {
            'dossierId': dossierId,
            'updates': {'observations': 'new'},
          },
    );
    await db.insert('sync_operations', {
      'id': table,
      'entity_type': table,
      'entity_local_id': dossierId,
      'operation_type': 'update',
      'payload_json': encoded,
      'status': status,
      'created_at': _old,
      'updated_at': _old,
    });
    return SyncOperation(
      id: table,
      entityType: table,
      entityLocalId: dossierId,
      operationType: 'update',
      payloadJson: encoded,
      status: SyncOperationStatus.running,
      attemptCount: 0,
      createdAt: DateTime.parse(_old),
      updatedAt: DateTime.parse(_old),
    );
  }

  test(
    'fresh schema includes nullable own versions in exactly three children',
    () async {
      for (final table in [
        ..._tables,
        'contexte_de_vie',
        'visit_recommendations',
      ]) {
        final columns = await db.rawQuery('PRAGMA table_info($table)');
        final versions = columns.where((r) => r['name'] == 'remote_updated_at');
        expect(versions.length, _tables.contains(table) ? 1 : 0);
        if (versions.isNotEmpty) {
          expect(versions.single['type'], 'TEXT');
          expect(versions.single['notnull'], 0);
        }
      }
    },
  );

  test(
    'v22 migration is additive, repeatable and preserves queued payloads',
    () async {
      for (final table in _tables) {
        await seed(table);
        await db.execute('ALTER TABLE $table DROP COLUMN remote_updated_at');
      }
      final before = await db.query('sync_operations');
      await local.upgradeSchemaForTesting(22);
      await local.upgradeSchemaForTesting(22);
      expect(await db.query('sync_operations'), before);
      for (final table in _tables) {
        final row = (await db.query(table)).single;
        expect(row['local_id'], '$table-row');
        expect(row['sync_state'], 'pendingSync');
        expect(row['updated_at'], _old);
        expect(row['remote_updated_at'], isNull);
      }
    },
  );

  for (final table in _tables) {
    test(
      '$table stores version by dossier key and acknowledges exact payload',
      () async {
        final operation = await seed(table);
        await repository.storeRemoteUpdatedAt(operation, _new);
        expect((await db.query(table)).single['remote_updated_at'], _new);
        expect((await db.query(table)).single['sync_state'], 'pendingSync');
        expect(await repository.markCompletedForPayload(operation), isTrue);
        expect((await db.query(table)).single['sync_state'], 'synced');
      },
    );

    for (final state in ['running', 'pending', 'conflict']) {
      test(
        '$table late reply cannot overwrite replaced $state payload',
        () async {
          final operation = await seed(table);
          await db.update('sync_operations', {
            'payload_json': '{"newer":true}',
            'status': state,
          });
          await repository.storeRemoteUpdatedAt(operation, _new);
          expect(await repository.markCompletedForPayload(operation), isFalse);
          expect((await db.query(table)).single['remote_updated_at'], _old);
          expect((await db.query(table)).single['sync_state'], 'pendingSync');
          expect((await db.query('sync_operations')).single['status'], state);
        },
      );
    }

    test('$table null ACK version preserves previous timestamp', () async {
      final operation = await seed(table);
      await repository.storeRemoteUpdatedAt(operation, null);
      expect((await db.query(table)).single['remote_updated_at'], _old);
    });

    for (final guarded in [true, false]) {
      test('$table sync forwards only captured concurrency ($guarded)', () async {
        final updates = table == 'diagnostic_sanitaires'
            ? <String, dynamic>{
                'sdbInstances': [
                  {'id': 'new-sdb'},
                ],
                'wcInstances': [],
              }
            : <String, dynamic>{'observations': 'new'};
        await seed(
          table,
          status: 'pending',
          payload: {
            'dossierId': 'local_dossier',
            'updates': updates,
            if (table == 'diagnostic_sanitaires')
              'sdbInstances': [
                {'id': 'stale-root'},
              ],
            if (guarded) 'concurrency': _guard else 'localReference': _guard,
          },
        );
        // The dossier timestamp deliberately differs from the captured child version.
        await db.insert('dossiers', {
          'local_id': 'local_dossier',
          'remote_dossier_id': 'remote-dossier',
          'patient_local_id': 'patient',
          'housing_local_id': 'housing',
          'status': 'EN_COURS',
          'ergo_id': 'ergo',
          'autonomy_notes': '',
          'plans_json': '[]',
          'created_at': _old,
          'sync_state': 'synced',
          'remote_updated_at': _new,
          'updated_at': _old,
        });
        var requests = 0;
        final client = NocodbApiClient(
          client: MockClient((request) async {
            requests++;
            expect(request.url.pathSegments.last, 'remote-dossier');
            final body = jsonDecode(request.body) as Map;
            expect(body['expectedUpdatedAt'], guarded ? _old : null);
            expect(body['concurrency'], guarded ? _guard : null);
            expect(body.containsKey('localReference'), isFalse);
            for (final entry in updates.entries) {
              expect(body[entry.key], entry.value);
            }
            return http.Response(
              jsonEncode({
                'data': {'updatedAt': _new},
              }),
              200,
            );
          }),
        );
        final result = await NocodbSyncService(
          apiClient: client,
          syncRepository: repository,
        ).pushPendingChanges();
        expect(requests, 1);
        expect(result.pushedOperations, 1);
        expect((await db.query(table)).single['remote_updated_at'], _new);
        expect((await db.query(table)).single['sync_state'], 'synced');
      });
    }

    test(
      '$table unconfirmed guarded response keeps exact mutation for retry',
      () async {
        final updates = table == 'diagnostic_sanitaires'
            ? <String, dynamic>{'sdbInstances': [], 'wcInstances': []}
            : <String, dynamic>{'observations': 'new'};
        final operation = await seed(
          table,
          dossierId: 'remote-dossier',
          status: 'pending',
          payload: {
            'dossierId': 'remote-dossier',
            'updates': updates,
            'concurrency': _guard,
          },
        );
        var requests = 0;
        final client = NocodbApiClient(
          client: MockClient((request) async {
            requests++;
            expect((jsonDecode(request.body) as Map)['concurrency'], _guard);
            return http.Response(
              requests == 1
                  ? '{}'
                  : jsonEncode({
                      'data': {'updatedAt': _new},
                    }),
              200,
            );
          }),
        );
        final service = NocodbSyncService(
          apiClient: client,
          syncRepository: repository,
        );
        final first = await service.pushPendingChanges();
        expect(first.pushedOperations, 0);
        expect(first.deferredOperations, 1);
        final pending = (await db.query('sync_operations')).single;
        expect(pending['status'], isNot('completed'));
        expect(pending['payload_json'], operation.payloadJson);
        expect((await db.query(table)).single['remote_updated_at'], _old);
        expect((await db.query(table)).single['sync_state'], isNot('synced'));
        // Simulate the next retry after the backoff without changing its payload.
        await db.update('sync_operations', {'updated_at': _old});
        final second = await service.pushPendingChanges();
        expect(second.pushedOperations, 1);
        expect(requests, 2);
        expect((await db.query(table)).single['remote_updated_at'], _new);
      },
    );

    test(
      '$table unresolved offline dossier is deferred without HTTP',
      () async {
        await seed(table, status: 'pending');
        var requests = 0;
        final client = NocodbApiClient(
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        final result = await NocodbSyncService(
          apiClient: client,
          syncRepository: repository,
        ).pushPendingChanges();
        expect(requests, 0);
        expect(result.deferredOperations, 1);
        expect((await db.query(table)).single['remote_updated_at'], _old);
      },
    );

    test(
      '$table missing captured timestamp is a conflict, never dossier fallback',
      () async {
        await seed(
          table,
          status: 'pending',
          payload: {
            'dossierId': 'local_dossier',
            'updates': <String, dynamic>{},
            'concurrency': {..._guard, 'expectedUpdatedAt': null},
          },
        );
        var requests = 0;
        final client = NocodbApiClient(
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        final result = await NocodbSyncService(
          apiClient: client,
          syncRepository: repository,
        ).pushPendingChanges();
        expect(requests, 0);
        expect(result.conflictCount, 1);
        expect((await db.query(table)).single['sync_state'], 'conflict');
      },
    );
  }
}
