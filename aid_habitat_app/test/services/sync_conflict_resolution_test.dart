import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:aid_habitat_app/services/sync_mutation.dart';
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
  'housing': <String, dynamic>{
    'id': 'housing-1',
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

  Future<void> conflict(String type, {Map<String, dynamic>? remoteData}) async {
    final ops = await queue.fetchRunnableOperations();
    final op = ops.singleWhere((op) => op.entityType == type);
    expect(await queue.tryMarkRunning(op), isTrue);
    await queue.markConflict(
      operationId: op.id,
      entityType: op.entityType,
      entityLocalId: op.entityLocalId,
      error: 'synthetic conflict',
      expectedPayloadJson: op.payloadJson,
      remoteData:
          remoteData ??
          {
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

  test(
    'legacy collection queue stays intact until explicit reviewed upgrade',
    () async {
      await dossiers.updatePatient('patient-1', {
        'dependence_txt': 'Canne, Orthèse inconnue',
      });
      final authored = await payload();
      expect(authored['concurrency']['collectionContract'], 'collections-v2');
      // Simulate a build64/70 operation stored before upgrading the application.
      (authored['concurrency'] as Map).remove('collectionContract');
      await db.update('sync_operations', {
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode(authored),
        ),
      });
      await dossiers.updatePatient('patient-1', {'phone': '456'});
      expect((await payload())['concurrency']['collectionContract'], isNull);
      await conflict('patient');
      final beforeReview = await payload();
      final server = remote(version: _new);
      (server['patient'] as Map)['dependenceTxt'] = 'Déambulateur';
      final reviews = await dossiers.reviewConflicts('dossier-1', server);
      expect(
        reviews.single.localValues['dependenceTxt'],
        'Canne, Orthèse inconnue',
      );
      expect(reviews.single.remoteValues['dependenceTxt'], 'Déambulateur');
      expect(await payload(), beforeReview);
      await dossiers.resolveReviewedConflict(reviews.single, keepLocal: true);
      final after = await payload();
      expect(after['concurrency']['collectionContract'], 'collections-v2');
      expect(after['concurrency']['expectedUpdatedAt'], _new);
      expect(
        after['concurrency']['writeId'],
        isNot(beforeReview['concurrency']['writeId']),
      );
      expect(after['updates']['dependenceTxt'], 'Canne, Orthèse inconnue');
      expect(after['updates']['phone'], '456');
      final history = (await db.query('sync_conflict_history')).single;
      final snapshot = jsonDecode(
        await OfflineVault.instance.openString(
          history['snapshot_json'] as String,
        ),
      );
      expect(snapshot['mutation'], beforeReview);
    },
  );

  test(
    'blank remote birth date can be reviewed and local date retained',
    () async {
      final raw = remote();
      final occupants = [
        {'firstName': 'Original', 'lastName': 'Synthetic', 'birthDate': ''},
      ];
      raw['patient'] = <String, dynamic>{
        ...raw['patient'] as Map,
        'birthDate': null,
        'occupant1BirthDate': null,
        'occupants': occupants,
      };
      await dossiers.mergeRemoteDossierPayloads([raw]);
      await dossiers.updatePatient('patient-1', {
        'birth_date': '1966-08-04',
        'occupants_json': jsonEncode([
          {...occupants.single, 'birthDate': '1966-08-04'},
        ]),
      });
      await conflict('patient');
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      expect(review.localValues['occupant1BirthDate'], '1966-08-04');
      expect(review.remoteValues['occupant1BirthDate'], '');
      await dossiers.resolveReviewedConflict(review, keepLocal: true);
      expect((await payload())['updates']['occupant1BirthDate'], '1966-08-04');
      expect((await payload())['concurrency']['expectedUpdatedAt'], _old);
      expect((await db.query('patients')).single['birth_date'], '1966-08-04');
    },
  );

  for (final keepFunds in [true, false]) {
    test(
      'mixed pension and email resolution preserves selected values $keepFunds',
      () async {
        final occupants = [
          {
            'firstName': 'Local',
            'caisseRetraitePrincipale': 'CNAV',
            'caissesRetraiteComplementaires': 'Malakoff Humanis',
          },
        ];
        await dossiers.updatePatient('patient-1', {
          'caisse_retraite_principale': 'CNAV',
          'caisses_retraite_complementaires': 'Malakoff Humanis',
          'occupants_json': jsonEncode(occupants),
          'email': 'old-local@example.test',
        });
        await conflict('patient');
        final raw = remote(version: _new);
        raw['patient'] = <String, dynamic>{
          ...(raw['patient'] as Map<String, dynamic>),
          'email': 'server@example.test',
          'caisseRetraitePrincipale': 'CNBF',
          'caissesRetraiteComplementaires': 'AG2R',
          'occupants': [
            {'firstName': 'Local', 'caisseRetraitePrincipale': 'Aucune'},
          ],
        };
        final review = (await dossiers.reviewConflicts(
          'dossier-1',
          raw,
        )).single;
        final selected = keepFunds
            ? {
                'occupants',
                'caisseRetraitePrincipale',
                'caissesRetraiteComplementaires',
              }
            : <String>{};
        await dossiers.resolveReviewedConflict(
          review,
          keepLocal: true,
          localFields: selected,
        );
        final row = (await db.query('patients')).single;
        expect(row['email'], 'server@example.test');
        expect(row['phone'], '123');
        expect(row['caisse_retraite_principale'], keepFunds ? 'CNAV' : 'CNBF');
        expect(
          row['caisses_retraite_complementaires'],
          keepFunds ? 'Malakoff Humanis' : 'AG2R',
        );
        final mutation = await payload();
        expect((mutation['updates'] as Map).keys.toSet(), selected);
        expect(
          mutation['concurrency']['baseValues']['email'],
          'server@example.test',
        );
        expect(mutation['concurrency']['expectedUpdatedAt'], _new);
        expect(
          (await db.query('sync_operations')).single['status'],
          keepFunds ? 'pending' : 'completed',
        );
        expect(row['sync_state'], keepFunds ? 'pendingSync' : 'synced');
        final history = (await db.query('sync_conflict_history')).single;
        expect(history['decision'], 'merge_fields');
        final snapshot = jsonDecode(
          await OfflineVault.instance.openString(
            history['snapshot_json'] as String,
          ),
        );
        expect(
          snapshot['mutation']['updates']['email'],
          'old-local@example.test',
        );
        expect((snapshot['localFields'] as List).toSet(), selected);
        await expectLater(
          dossiers.resolveReviewedConflict(
            review,
            keepLocal: true,
            localFields: selected,
          ),
          throwsStateError,
        );
      },
    );
  }

  test(
    'housing field choices retain server fields and archive both versions',
    () async {
      await dossiers.updateHousing('dossier-1', {
        'surface': 90,
        'rdc_desc': 'Cuisine locale',
      });
      await conflict('housing');
      final raw = remote(version: _new);
      (raw['housing'] as Map)['surface'] = 100;
      (raw['housing'] as Map)['rdcDesc'] = 'Salon serveur';
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      await dossiers.resolveReviewedConflict(
        review,
        keepLocal: true,
        localFields: {'surface'},
      );
      final saved = (await db.query('housings')).single;
      expect(saved['surface'], 90);
      expect(saved['rdc_desc'], 'Salon serveur');
      expect((await payload())['updates'], {'surface': 90});
      expect((await db.query('sync_operations')).single['status'], 'pending');
      final history = (await db.query('sync_conflict_history')).single;
      final snapshot = jsonDecode(
        await OfflineVault.instance.openString(
          history['snapshot_json'] as String,
        ),
      );
      expect(snapshot['mutation']['updates']['rdcDesc'], 'Cuisine locale');
      expect(snapshot['remoteValues']['surface'], 100);
    },
  );

  for (final answer in [true, false]) {
    test(
      'entered accessibility answer $answer resumes against an empty server field',
      () async {
        await dossiers.updateHousing('dossier-1', {
          'easy_access': answer ? 1 : 0,
          'easy_access_set': 1,
        });
        expect((await payload())['updates']['easyAccess'], answer);
        expect(
          (await payload())['concurrency']['baseValues']['easyAccess'],
          isNull,
        );
        await conflict(
          'housing',
          remoteData: {
            'error': 'SYNC_FIELD_CONFLICT',
            'remoteUpdatedAt': _new,
            'remoteData': {'acces_facile_rue': null},
          },
        );
        final raw = remote(version: _new);
        (raw['housing'] as Map)['easyAccess'] = null;
        final review = (await dossiers.reviewConflicts(
          'dossier-1',
          raw,
        )).single;
        final plan = planSyncMerge(
          baseValues: {'easyAccess': answer},
          updates: review.localValues,
          remoteValues: review.remoteValues,
        );
        expect(plan.canApplyAutomatically, isTrue);
        await dossiers.resolveReviewedConflict(
          review,
          keepLocal: true,
          localFields: plan.updates.keys.toSet(),
        );
        expect((await payload())['updates']['easyAccess'], answer);
        expect((await db.query('sync_operations')).single['status'], 'pending');
        final saved = (await db.query('housings')).single;
        expect(saved['easy_access'], answer ? 1 : 0);
        expect(saved['easy_access_set'], 1);
      },
    );
  }

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
    'legacy housing with empty remote levels retains all local rooms',
    () async {
      await dossiers.updateHousing('dossier-1', {
        'levels': 2,
        'surface': 91.0,
        'rdc_rooms_json': '["Salon", "Cuisine", "Salle de bain"]',
      });
      final authored = await payload();
      (authored['concurrency'] as Map).remove('collectionContract');
      await db.update('sync_operations', {
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode(authored),
        ),
      });
      await conflict(
        'housing',
        remoteData: {'error': 'COLLECTION_CLIENT_UPGRADE_REQUIRED'},
      );
      final before = await payload();
      final raw = remote(version: _new);
      raw['housing'] = <String, dynamic>{
        ...raw['housing'] as Map,
        'levels': null,
      };
      (raw['housing'] as Map)['roomsBreakdown'] = {
        'rdc': ['Salle de bain'],
        'basement': [],
        'floor': [],
        'secondFloor': [],
        'thirdFloor': [],
      };
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      expect(review.remoteValues['levels'], isNull);
      expect(review.localValues['levels'], 2);
      expect(await payload(), before);
      await dossiers.resolveReviewedConflict(review, keepLocal: true);
      final after = await payload();
      expect(after['updates'], before['updates']);
      expect(after['concurrency']['collectionContract'], 'collections-v2');
      expect(after['concurrency']['baseValues']['levels'], isNull);
      expect((await db.query('housings')).single['levels'], 2);
      final history = (await db.query('sync_conflict_history')).single;
      final snapshot = jsonDecode(
        await OfflineVault.instance.openString(
          history['snapshot_json'] as String,
        ),
      );
      expect(snapshot['mutation'], before);
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

  for (final keepLocal in [true, false]) {
    test('explicit null rooms are reviewable, keepLocal=$keepLocal', () async {
      await dossiers.updateHousing('dossier-1', {
        'rdc_rooms_json': '["Local"]',
      });
      await conflict('housing');
      final raw = remote(version: _new);
      raw['housing'] = {...(raw['housing'] as Map), 'roomsBreakdown': null};
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      expect((review.remoteValues['roomsBreakdown'] as Map)['rdc'], isEmpty);
      expect(
        jsonDecode(
          (await db.query('housings')).single['rdc_rooms_json'] as String,
        ),
        ['Local'],
      );
      await dossiers.resolveReviewedConflict(review, keepLocal: keepLocal);
      expect(
        jsonDecode(
          (await db.query('housings')).single['rdc_rooms_json'] as String,
        ),
        keepLocal ? ['Local'] : [],
      );
    });
  }

  test(
    'null room conflict retries once with original guard and local data intact',
    () async {
      await db.update('housings', {'rdc_rooms_json': '[]'});
      await dossiers.updateHousing('dossier-1', {
        'rdc_rooms_json': '["Local"]',
      });
      await conflict(
        'housing',
        remoteData: {
          'error': 'SYNC_FIELD_CONFLICT',
          'remoteUpdatedAt': _new,
          'remoteData': {'rooms_breakdown_json': null},
        },
      );
      final original = await payload();
      expect(await queue.recoverEmptyHousingRoomConflicts(), 1);
      expect((await payload())['concurrency'], original['concurrency']);
      expect((await payload())['updates'], original['updates']);
      expect(
        jsonDecode(
          (await db.query('housings')).single['rdc_rooms_json'] as String,
        ),
        ['Local'],
      );
      await conflict(
        'housing',
        remoteData: {
          'error': 'SYNC_FIELD_CONFLICT',
          'remoteUpdatedAt': _new,
          'remoteData': {'rooms_breakdown_json': null},
        },
      );
      expect(await queue.recoverEmptyHousingRoomConflicts(), 0);
    },
  );

  test(
    'real room changes and unknown baselines are never automatically retried',
    () async {
      await dossiers.updateHousing('dossier-1', {
        'rdc_rooms_json': '["Local"]',
      });
      await conflict(
        'housing',
        remoteData: {
          'error': 'SYNC_FIELD_CONFLICT',
          'remoteUpdatedAt': _new,
          'remoteData': {'rooms_breakdown_json': null},
        },
      );
      final before = await db.query('sync_operations');
      expect(await queue.recoverEmptyHousingRoomConflicts(), 0);
      expect(await db.query('sync_operations'), before);
    },
  );

  Future<void> legacyAccessConflict({
    String version = _old,
    Object? observed,
    List<String> fields = const ['acces_facile_rue'],
  }) async {
    await dossiers.updateHousing('dossier-1', {
      'easy_access': 1,
      'easy_access_set': 1,
      'garage': 1,
    });
    final old = await payload();
    old['concurrency']['baseValues']['easyAccess'] = false;
    await db.update('sync_operations', {
      'payload_json': await OfflineVault.instance.sealString(jsonEncode(old)),
    });
    await conflict(
      'housing',
      remoteData: {
        'error': 'SYNC_FIELD_CONFLICT',
        'remoteUpdatedAt': version,
        'conflictFields': fields,
        'retainedFields': [],
        'remoteData': {'acces_facile_rue': observed},
      },
    );
  }

  test(
    'automatic accessibility recovery never touches another author’s queue or ownership',
    () async {
      await db.insert('app_session', {
        'id': 1,
        'user_local_id': 'ergo-a',
        'created_at': _old,
        'updated_at': _old,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await SyncOperationOwnership.installMigration(db);
      await legacyAccessConflict();
      final originalOps = await db.query('sync_operations');
      final originalOwners = await db.query(SyncOperationOwnership.tableName);
      await db.update('app_session', {'user_local_id': 'ergo-b'});
      final productionQueue = SyncRepository(databaseProvider: () async => db);
      expect(
        await productionQueue.recoverUnansweredHousingAccessConflicts(),
        0,
      );
      expect(await db.query('sync_operations'), originalOps);
      expect(await db.query(SyncOperationOwnership.tableName), originalOwners);
      await db.update('app_session', {'user_local_id': 'ergo-a'});
      expect(
        await productionQueue.recoverUnansweredHousingAccessConflicts(),
        1,
      );
    },
  );

  test(
    'legacy empty accessibility conflict resumes once with original write and values preserved',
    () async {
      await legacyAccessConflict();
      final before = await payload();
      expect(await queue.recoverUnansweredHousingAccessConflicts(), 1);
      final after = await payload();
      expect(after['concurrency'], before['concurrency']);
      expect(after['updates'], before['updates']);
      expect(after.containsKey('conflict'), isFalse);
      expect((await db.query('housings')).single['easy_access'], 1);
      expect(
        (await db.query('sync_conflict_history')).single['decision'],
        'retry_unanswered_housing_access',
      );
      await conflict('housing', remoteData: before['conflict']['remote']);
      expect(await queue.recoverUnansweredHousingAccessConflicts(), 0);
    },
  );

  test(
    'a later web edit keeps its conflict and never triggers recovery',
    () async {
      await legacyAccessConflict(version: _new);
      final before = await payload();
      expect(canAutomaticallyResumeConflict(before), isFalse);
      expect(await queue.recoverUnansweredHousingAccessConflicts(), 0);
      expect(await payload(), before);
    },
  );

  test('an explicit web answer keeps its conflict', () async {
    await legacyAccessConflict(observed: false);
    expect(await queue.recoverUnansweredHousingAccessConflicts(), 0);
  });

  test('multiple conflicting fields are never auto-retried', () async {
    await legacyAccessConflict(fields: ['acces_facile_rue', 'garage']);
    expect(await queue.recoverUnansweredHousingAccessConflicts(), 0);
  });

  test(
    'missing remote housing is reviewable and keep-local becomes a guarded create',
    () async {
      await db.update('housings', {'remote_updated_at': null});
      await dossiers.updateHousing('dossier-1', {'surface': 91.0});
      await conflict('housing');
      final raw = remote(version: _new);
      raw['housing'] = {
        'basement': false,
        'rdc': false,
        'floor': false,
        'garage': false,
        'veranda': false,
        'balcon': false,
        'terrasse': false,
        'jardin': false,
        'heatingMain': false,
        'heatingDetails': {
          'electric': false,
          'gas': false,
          'oil': false,
          'heatPump': false,
          'collective': false,
          'wood': false,
          'pellet': false,
          'other': false,
        },
        'easyAccess': null,
      };
      final review = (await dossiers.reviewConflicts('dossier-1', raw)).single;
      expect(review.remoteExists, isFalse);
      expect(review.remoteUpdatedAt, isNull);
      expect(review.localValues, {'surface': 91.0});
      expect(review.remoteValues, {'surface': null});
      await expectLater(
        dossiers.resolveReviewedConflict(review, keepLocal: false),
        throwsStateError,
      );
      expect((await db.query('housings')).single['surface'], 91.0);
      await dossiers.resolveReviewedConflict(review, keepLocal: true);
      final op = await payload();
      expect(op['concurrency']['createIfAbsent'], isTrue);
      expect(op['concurrency']['expectedUpdatedAt'], isNull);
      expect(op['concurrency']['baseValues'], isEmpty);
      expect((await db.query('housings')).single['surface'], 91.0);
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
