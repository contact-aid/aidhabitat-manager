import 'dart:convert';

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

const _dossierVersion = '2026-09-01T08:00:00.000Z';
const _childVersions = <String, String>{
  'mesures_anthropometriques': '2026-09-01T09:00:00.000Z',
  'observations_synthese': '2026-09-01T10:00:00.000Z',
  'diagnostic_sanitaires': '2026-09-01T11:00:00.000Z',
};
const _ackVersions = <String, String>{
  'mesures_anthropometriques': '2026-09-10T09:00:00.000Z',
  'observations_synthese': '2026-09-10T10:00:00.000Z',
  'diagnostic_sanitaires': '2026-09-10T11:00:00.000Z',
};

String _routeFor(String table) => switch (table) {
  'mesures_anthropometriques' => 'mesures',
  'observations_synthese' => 'observations',
  _ => 'diagnostic-sanitaires',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SyncRepository queue;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    queue = SyncRepository.forTesting(database: local);
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
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
    await ConnectivityService().initialize();

    await db.insert('dossiers', {
      'local_id': 'local-dossier',
      'remote_dossier_id': 'remote-dossier',
      'patient_local_id': 'patient-1',
      'housing_local_id': 'housing-1',
      'status': 'IN_PROGRESS',
      'ergo_id': 'synthetic-ergo',
      'autonomy_notes': '',
      'plans_json': '[]',
      'created_at': _dossierVersion,
      'updated_at': _dossierVersion,
      'remote_updated_at': _dossierVersion,
      'sync_state': 'synced',
    });
    for (final entry in _childVersions.entries) {
      await db.insert(entry.key, {
        'local_id': '${entry.key}-row',
        'dossier_local_id': 'local-dossier',
        'remote_updated_at': entry.value,
        'updated_at': entry.value,
        'sync_state': 'pendingSync',
      });
      final updates = entry.key == 'diagnostic_sanitaires'
          ? <String, dynamic>{'sdbInstances': [], 'wcInstances': []}
          : <String, dynamic>{'observations': '${entry.key} local edit'};
      final payload = jsonEncode({
        'dossierId': 'local-dossier',
        'updates': updates,
        'concurrency': {
          'version': 1,
          'writeId':
              '12345678-1234-4234-8234-${entry.value.substring(11, 13)}0000000000',
          'expectedUpdatedAt': entry.value,
          'baseValues': <String, dynamic>{},
        },
      });
      await db.insert('sync_operations', {
        'id': '${entry.key}-update',
        'entity_type': entry.key,
        'entity_local_id': 'local-dossier',
        'operation_type': 'update',
        'payload_json': payload,
        'status': 'pending',
        'attempt_count': 0,
        'created_at': _dossierVersion,
        'updated_at': _dossierVersion,
      });
    }
  });

  tearDown(() async {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
    await db.close();
  });

  test(
    'concurrent secondary writes keep and acknowledge their own versions',
    () async {
      final seen = <String>{};
      final client = NocodbApiClient(
        client: MockClient((request) async {
          final table = _childVersions.keys.singleWhere(
            (candidate) =>
                request.url.path ==
                '/api/${_routeFor(candidate)}/remote-dossier',
          );
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['expectedUpdatedAt'], _childVersions[table]);
          expect(
            (body['concurrency'] as Map)['expectedUpdatedAt'],
            _childVersions[table],
          );
          expect(body['expectedUpdatedAt'], isNot(_dossierVersion));
          seen.add(table);
          return http.Response(
            jsonEncode({
              'data': {'updatedAt': _ackVersions[table]},
            }),
            200,
          );
        }),
      );

      final result = await NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();

      expect(result.pushedOperations, 3);
      expect(seen, _childVersions.keys.toSet());
      for (final table in _childVersions.keys) {
        final row = (await db.query(table)).single;
        expect(row['remote_updated_at'], _ackVersions[table]);
        expect(row['sync_state'], 'synced');
        final operation = (await db.query(
          'sync_operations',
          where: 'entity_type = ?',
          whereArgs: [table],
        )).single;
        expect(operation['status'], 'completed');
      }
    },
  );
}
