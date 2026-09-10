import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  late DossierRepository dossiers;
  late SyncRepository queue;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    dossiers = DossierRepository(database: local);
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
  });

  tearDown(() async {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
    await db.close();
  });

  test(
    'offline local identities survive remote id assignment and all created rows are acknowledged',
    () async {
      final created = await dossiers.createDossierOffline(
        firstName: 'Offline',
        lastName: 'Synthetic',
        city: 'Test City',
      );
      final patientLocalId = created.patient.id;
      final dossierLocalId = created.id;
      final housingBefore = (await db.query('housings')).single;
      final housingLocalId = housingBefore['local_id'];
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'POST');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['clientLocalId'], patientLocalId);
          return http.Response(
            '{"data":{"id":"remote-patient-1","dossierId":"remote-dossier-1"}}',
            201,
          );
        }),
      );

      final result = await NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      final patient = (await db.query('patients')).single;
      final housing = (await db.query('housings')).single;
      final dossier = (await db.query('dossiers')).single;

      expect(result.pushedOperations, 1);
      expect(patient['local_id'], patientLocalId);
      expect(housing['local_id'], housingLocalId);
      expect(dossier['local_id'], dossierLocalId);
      expect(dossier['patient_local_id'], patientLocalId);
      expect(dossier['housing_local_id'], housingLocalId);
      expect(patient['remote_patient_id'], 'remote-patient-1');
      expect(dossier['remote_dossier_id'], 'remote-dossier-1');
      expect(patient['sync_state'], 'synced');
      expect(dossier['sync_state'], 'synced');
      expect(
        housing['sync_state'],
        'synced',
        reason: 'the create acknowledgement also represents the remote housing',
      );
    },
  );

  test(
    'a patient edit made during offline dossier creation stays pending after the create ACK',
    () async {
      final created = await dossiers.createDossierOffline(
        firstName: 'Before request',
        lastName: 'Synthetic',
      );
      final requestEntered = Completer<void>();
      final releaseReply = Completer<void>();
      final client = NocodbApiClient(
        client: MockClient((_) async {
          requestEntered.complete();
          await releaseReply.future;
          return http.Response(
            '{"data":{"id":"remote-patient-2","dossierId":"remote-dossier-2"}}',
            201,
          );
        }),
      );

      final push = NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      await requestEntered.future;
      await dossiers.updatePatient(created.patient.id, {
        'first_name': 'Edited while POST was in flight',
      });
      releaseReply.complete();
      await push;

      final patient = (await db.query('patients')).single;
      final patientOp = (await db.query(
        'sync_operations',
        where: "entity_type = 'patient'",
      )).single;
      expect(patient['first_name'], 'Edited while POST was in flight');
      expect(patientOp['status'], 'pending');
      expect(
        patient['sync_state'],
        'pendingSync',
        reason:
            'the create response did not acknowledge the newer patient edit',
      );
    },
  );
}
