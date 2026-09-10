import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _old = '2026-09-01T10:00:00.000Z';
const _new = '2026-09-02T10:00:00.000Z';

Map<String, dynamic> remote({
  String name = 'Original',
  String version = _old,
}) => {
  'id': 'dossier-1',
  'updatedAt': version,
  'createdAt': _old,
  'workspaceUpdatedAt': version,
  'status': 'IN_PROGRESS',
  'patient': {
    'id': 'patient-1',
    'firstName': name,
    'lastName': 'Synthetic',
    'phone': '123',
    'updatedAt': version,
  },
  'housing': {
    'surface': 80,
    'updatedAt': version,
    'roomsBreakdown': {
      'basement': [],
      'rdc': ['Cuisine'],
      'floor': [],
      'secondFloor': [],
      'thirdFloor': [],
    },
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository dossiers;
  late SyncRepository queue;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    dossiers = DossierRepository(database: local);
    queue = SyncRepository.forTesting(database: local);
    await dossiers.mergeRemoteDossierPayloads([remote()]);
  });
  tearDown(() async => db.close());

  test(
    'v21 upgrade adds history without changing queued or local data',
    () async {
      await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
      final before = await db.query('sync_operations');
      await db.execute('DROP TABLE sync_conflict_history');
      await LocalDatabase.forTesting(db).upgradeSchemaForTesting(21);
      expect(await db.query('sync_operations'), before);
      expect((await db.query('patients')).single['first_name'], 'Local');
      expect(await db.query('sync_conflict_history'), isEmpty);
    },
  );

  Future<void> conflict(String type) async {
    final ops = await queue.fetchRunnableOperations();
    final op = ops.singleWhere((op) => op.entityType == type);
    expect(await queue.tryMarkRunning(op), isTrue);
    await queue.markConflict(
      operationId: op.id,
      entityType: op.entityType,
      entityLocalId: op.entityLocalId,
      error: 'synthetic conflict',
      expectedPayloadJson: op.payloadJson,
      remoteData: {
        'remoteUpdatedAt': _new,
        'remoteData': {'prenom': 'Remote'},
      },
    );
  }

  Future<Map<String, dynamic>> payload() async =>
      jsonDecode(
            await OfflineVault.instance.openString(
              (await db.query('sync_operations')).single['payload_json']
                  as String,
            ),
          )
          as Map<String, dynamic>;

  test('409 preserves both versions, blocks boot and protects pull', () async {
    await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
    await conflict('patient');
    expect(
      (await payload())['conflict']['remote']['remoteData']['prenom'],
      'Remote',
    );
    await queue.restoreConflictedEntities();
    await dossiers.mergeRemoteDossierPayloads([
      remote(name: 'Remote', version: _new),
    ]);
    expect((await db.query('patients')).single['first_name'], 'Local');
    expect((await db.query('patients')).single['sync_state'], 'conflict');
    expect(await queue.fetchRunnableOperations(), isEmpty);
    expect(
      await queue.countConflictingReportPrerequisites(
        dossierId: 'dossier-1',
        patientId: 'patient-1',
      ),
      1,
    );
  });

  test(
    'take remote changes only reviewed fields and archives both versions',
    () async {
      await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
      await dossiers.updateDossierFields('dossier-1', {
        'compte_anah': 'other local edit',
      });
      await conflict('patient');
      final raw = remote(name: 'Remote', version: _new);
      (raw['patient'] as Map)['phone'] = '999';
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      expect(review.localValues, {'firstName': 'Local'});
      expect(review.remoteValues, {'firstName': 'Remote'});
      await dossiers.resolveReviewedConflict(review, keepLocal: false);
      final patient = (await db.query('patients')).single;
      expect(patient['first_name'], 'Remote');
      expect(
        patient['phone'],
        '123',
        reason: 'unreviewed fields are not replaced',
      );
      expect(patient['sync_state'], 'synced');
      expect(
        (await db.query('dossiers')).single['compte_anah'],
        'other local edit',
      );
      final history = (await db.query('sync_conflict_history')).single;
      final snapshot = jsonDecode(
        await OfflineVault.instance.openString(
          history['snapshot_json'] as String,
        ),
      );
      expect(snapshot['mutation']['updates']['firstName'], 'Local');
      expect(snapshot['remoteValues']['firstName'], 'Remote');
      expect(history['decision'], 'take_remote');
      expect(
        (await queue.fetchRunnableOperations()).single.entityType,
        'dossier',
      );
    },
  );

  test(
    'keep local requeues with the reviewed version, never an unguarded retry',
    () async {
      await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
      await conflict('patient');
      final review = (await dossiers.reviewConflicts(
        'dossier-1',
        remote(name: 'Remote', version: _new),
      )).single;
      await dossiers.resolveReviewedConflict(review, keepLocal: true);
      final op = await payload();
      expect(op['updates'], {'firstName': 'Local'});
      expect(op['concurrency']['expectedUpdatedAt'], _new);
      expect(op['concurrency']['baseValues'], {'firstName': 'Remote'});
      expect(op.containsKey('conflict'), isFalse);
      expect((await db.query('patients')).single['sync_state'], 'pendingSync');
      expect(
        (await queue.fetchRunnableOperations()).single.entityType,
        'patient',
      );
    },
  );

  test(
    'new edit during review remains blocked and invalidates the old decision',
    () async {
      await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
      await conflict('patient');
      final review = (await dossiers.reviewConflicts(
        'dossier-1',
        remote(name: 'Remote', version: _new),
      )).single;
      await dossiers.updatePatient('patient-1', {
        'first_name': 'New local',
        'phone': '456',
      });
      expect((await db.query('sync_operations')).single['status'], 'conflict');
      expect((await db.query('patients')).single['sync_state'], 'conflict');
      expect(await queue.fetchRunnableOperations(), isEmpty);
      await expectLater(
        dossiers.resolveReviewedConflict(review, keepLocal: false),
        throwsStateError,
      );
      expect((await db.query('patients')).single['first_name'], 'New local');
      expect(await db.query('sync_conflict_history'), isEmpty);
    },
  );

  test(
    'transaction failure restores history, queue and local data together',
    () async {
      await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
      await conflict('patient');
      final review = (await dossiers.reviewConflicts(
        'dossier-1',
        remote(name: 'Remote', version: _new),
      )).single;
      await db.execute(
        "CREATE TRIGGER fail_resolution BEFORE UPDATE ON patients BEGIN SELECT RAISE(ABORT, 'synthetic disk error'); END",
      );
      await expectLater(
        dossiers.resolveReviewedConflict(review, keepLocal: false),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('patients')).single['first_name'], 'Local');
      expect((await db.query('sync_operations')).single['status'], 'conflict');
      expect(await db.query('sync_conflict_history'), isEmpty);
    },
  );

  test(
    'housing room arrays are restored as one field with all levels',
    () async {
      await dossiers.updateHousing('dossier-1', {
        'rdc_rooms_json': '["Local"]',
      });
      await conflict('housing');
      final raw = remote(version: _new);
      (raw['housing'] as Map)['roomsBreakdown'] = {
        'basement': ['Cave'],
        'rdc': ['Remote'],
        'floor': ['Chambre'],
        'secondFloor': [],
        'thirdFloor': [],
      };
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      await dossiers.resolveReviewedConflict(review, keepLocal: false);
      final housing = (await db.query('housings')).single;
      expect(jsonDecode(housing['rdc_rooms_json'] as String), ['Remote']);
      expect(jsonDecode(housing['basement_rooms_json'] as String), ['Cave']);
      expect(housing['surface'], 80);
    },
  );

  test('missing field or version is not manufactured for a decision', () async {
    await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
    await conflict('patient');
    final raw = remote(version: _new);
    (raw['patient'] as Map).remove('firstName');
    await expectLater(
      dossiers.reviewConflicts('dossier-1', raw),
      throwsStateError,
    );
    final noVersion = remote(version: _new);
    (noVersion['patient'] as Map).remove('updatedAt');
    await expectLater(
      dossiers.reviewConflicts('dossier-1', noVersion),
      throwsStateError,
    );
    expect((await db.query('sync_operations')).single['status'], 'conflict');
  });

  test('review from a different dossier or patient is rejected', () async {
    await dossiers.updatePatient('patient-1', {'first_name': 'Local'});
    await conflict('patient');
    await expectLater(
      dossiers.reviewConflicts('other', remote()),
      throwsStateError,
    );
    final raw = remote();
    (raw['patient'] as Map)['id'] = 'other';
    await expectLater(
      dossiers.reviewConflicts('dossier-1', raw),
      throwsStateError,
    );
  });
}
