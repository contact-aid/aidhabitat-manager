import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _dossier = 'dossier-1';
const _patient = 'patient-1';
const _dossierVersion = '2026-09-01T08:00:00.000Z';
const _pulled = '2026-09-02T09:00:00.000Z';
const _reviewed = '2026-09-03T10:00:00.000Z';
const _mesures = 'mesures_anthropometriques';
const _observations = 'observations_synthese';
const _diagnostic = 'diagnostic_sanitaires';
const _types = [_mesures, _observations, _diagnostic];
final _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, dynamic> _core({
  String dossierId = _dossier,
  String patientId = _patient,
}) => {
  'id': dossierId,
  'createdAt': _dossierVersion,
  'updatedAt': _dossierVersion,
  'workspaceUpdatedAt': _dossierVersion,
  'status': 'IN_PROGRESS',
  'patient': {
    'id': patientId,
    'firstName': 'Original',
    'lastName': 'Synthetic',
    'updatedAt': _dossierVersion,
  },
  'housing': {'surface': 80, 'updatedAt': _dossierVersion},
};

DiagnosticSanitaire _diag(int n, {String dossierId = _dossier}) =>
    DiagnosticSanitaire.fromJson({
      'dossierId': dossierId,
      'sdbInstances': [
        {'id': 'bath-$n', 'levelField': 'rdc'},
        {'id': 'bath-other-$n', 'levelField': 'floor'},
      ],
      'wcInstances': [
        {'id': 'wc-$n', 'levelField': 'rdc'},
      ],
    });

Map<String, dynamic> _child(
  String type, {
  int n = 0,
  String dossierId = _dossier,
  String? version = _pulled,
}) => {
  'dossierId': dossierId,
  if (version != null) 'updatedAt': version,
  ...switch (type) {
    _mesures => {
      'deboutHauteurCoude': 90.0,
      'assisHauteurAssise': 45.0,
      'assisProfondeurGenoux': null,
      'assisHauteurCoudes': null,
      'observations': 'measure-$n',
    },
    _observations => {
      'observationEquipements': 'untouched equipment',
      'projetSouhaitUsage': 'project-$n',
      'resumePreconisations': 'untouched summary',
    },
    _diagnostic => {
      'sdbInstances': _diag(n).toJson()['sdbInstances'],
      'wcInstances': _diag(n).toJson()['wcInstances'],
    },
    _ => throw StateError(type),
  },
};

Map<String, dynamic> _patch(String type, int n) => switch (type) {
  _mesures => {'observations': 'measure-$n'},
  _observations => {'projetSouhaitUsage': 'project-$n'},
  _diagnostic => {
    'sdbInstances': _diag(n).toJson()['sdbInstances'],
    'wcInstances': _diag(n).toJson()['wcInstances'],
  },
  _ => throw StateError(type),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  late DossierRepository repository;
  late SyncRepository queue;

  Future<bool> pull(String type, Map<String, dynamic> raw) => switch (type) {
    _mesures => repository.mergeRemoteMesuresPayload(_dossier, raw),
    _observations => repository.mergeRemoteObservationsPayload(_dossier, raw),
    _diagnostic => repository.mergeRemoteDiagnosticSanitairePayload(
      _dossier,
      raw,
    ),
    _ => throw StateError(type),
  };

  Future<void> edit(String type, int n, {String dossierId = _dossier}) =>
      switch (type) {
        _mesures => repository.upsertMesures(
          dossierId,
          MesuresAnthropometriques(
            dossierId: dossierId,
            deboutHauteurCoude: 90,
            assisHauteurAssise: 45,
            observations: 'measure-$n',
          ),
        ),
        _observations => repository.upsertObservations(
          dossierId,
          ObservationsSynthese(
            dossierId: dossierId,
            observationEquipements: 'untouched equipment',
            projetSouhaitUsage: 'project-$n',
            resumePreconisations: 'untouched summary',
          ),
        ),
        _diagnostic => repository.upsertDiagnosticSanitaire(
          dossierId,
          _diag(n, dossierId: dossierId),
        ),
        _ => throw StateError(type),
      };

  Future<Map<String, Object?>> operation(String type) async => (await db.query(
    'sync_operations',
    where: 'entity_type = ? AND operation_type = ?',
    whereArgs: [type, 'update'],
  )).single;

  Future<Map<String, dynamic>> payload(String type) async =>
      jsonDecode(
            await OfflineVault.instance.openString(
              (await operation(type))['payload_json'] as String,
            ),
          )
          as Map<String, dynamic>;

  Future<void> replacePayload(String type, Map<String, dynamic> value) async {
    final op = await operation(type);
    await db.update(
      'sync_operations',
      {
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode(value),
        ),
      },
      where: 'id = ?',
      whereArgs: [op['id']],
    );
  }

  Future<void> conflict(String type) async {
    final op = (await queue.fetchRunnableOperations()).singleWhere(
      (op) => op.entityType == type,
    );
    expect(await queue.tryMarkRunning(op), isTrue);
    await queue.markConflict(
      operationId: op.id,
      entityType: op.entityType,
      entityLocalId: op.entityLocalId,
      expectedPayloadJson: op.payloadJson,
      error: 'synthetic secondary conflict',
      remoteData: {'remoteUpdatedAt': _reviewed},
    );
  }

  Future<Map<String, List<Map<String, Object?>>>> snapshot() async => {
    for (final table in [
      'dossiers',
      'patients',
      'housings',
      ..._types,
      'sync_operations',
      'sync_conflict_history',
    ])
      table: await db.query(table, orderBy: 'rowid'),
  };

  Future<SyncConflictReview> review(String type) async =>
      (await repository.reviewSecondaryConflicts(_dossier, {
        type: _child(type, n: 9, version: _reviewed),
      })).single;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = DossierRepository(database: local);
    queue = SyncRepository.forTesting(database: local);
    await repository.mergeRemoteDossierPayloads([_core()]);
    for (final type in _types) {
      expect(await pull(type, _child(type)), isTrue);
    }
  });
  tearDown(() async => db.close());

  test('every visit child conflict can open its dossier', () async {
    for (final type in [
      'contexte_de_vie',
      'mesures_anthropometriques',
      'observations_synthese',
      'diagnostic_sanitaires',
    ]) {
      final id = 'review_$type';
      await db.insert('sync_operations', {
        'id': id,
        'entity_type': type,
        'entity_local_id': _dossier,
        'operation_type': 'update',
        'payload_json': '{}',
        'status': 'conflict',
        'created_at': _pulled,
        'updated_at': _pulled,
      });
      expect(await queue.conflictDossierId(id), _dossier);
    }
  });

  test('absent context row is reviewed as guarded creation', () async {
    await repository.upsertContexteDeVie(
      _dossier,
      _patient,
      medicalContext: const MedicalContext(pathology: 'synthetic'),
    );
    await conflict('contexte_de_vie');
    final before = await snapshot();
    final compared = (await repository.reviewSecondaryConflicts(_dossier, {
      'contexte_de_vie': {'dossierId': _dossier, 'serverReference': null},
    })).single;
    expect(compared.remoteExists, isFalse);
    expect(await snapshot(), before);
    await repository.resolveReviewedConflict(compared, keepLocal: true);
    final retry = await payload('contexte_de_vie');
    expect(retry['concurrency']['reference'], isNull);
    expect(retry['concurrency']['createIfAbsent'], isTrue);
  });

  test(
    'take remote context supplies the reference for the next height edit',
    () async {
      await repository.upsertContexteDeVie(
        _dossier,
        _patient,
        medicalContext: const MedicalContext(heightCm: '172', weightKg: '76.0'),
      );
      await conflict('contexte_de_vie');
      const reference = {
        'recordId': 501,
        'revision': '11111111-1111-4111-8111-111111111111',
        'updatedAt': _reviewed,
      };
      final compared = (await repository.reviewSecondaryConflicts(_dossier, {
        'contexte_de_vie': {
          'dossierId': _dossier,
          'serverReference': reference,
          'medicalContext': const MedicalContext(
            heightCm: '170',
            weightKg: '76.0',
          ).toJson(),
          'autonomy': const AutonomyData().toJson(),
        },
      })).single;
      await repository.resolveReviewedConflict(compared, keepLocal: false);
      final row = (await db.query('contexte_de_vie')).single;
      expect(row['remote_reference_known'], 1);
      expect(jsonDecode(row['remote_reference_json'] as String), reference);

      await repository.upsertContexteDeVie(
        _dossier,
        _patient,
        medicalContext: const MedicalContext(heightCm: '173', weightKg: '76.0'),
      );
      final next = await payload('contexte_de_vie');
      expect(next['updates'].keys, ['medicalContext']);
      expect(next['concurrency']['reference'], reference);
      expect(
        next['concurrency']['baseValues']['medicalContext']['heightCm'],
        '170',
      );
      expect((await operation('contexte_de_vie'))['status'], 'pending');
    },
  );

  test(
    'child conflict aggregates to dossier until every child is resolved',
    () async {
      expect(
        (await repository.fetchDossierById(_dossier))!.syncState,
        SyncState.synced,
      );
      await edit(_mesures, 1);
      await conflict(_mesures);
      expect(
        (await repository.fetchDossierById(_dossier))!.syncState,
        SyncState.conflict,
      );
      await edit(_observations, 1);
      await conflict(_observations);
      final compared = await repository.reviewSecondaryConflicts(_dossier, {
        _mesures: _child(_mesures, n: 9, version: _reviewed),
        _observations: _child(_observations, n: 9, version: _reviewed),
      });
      await repository.resolveReviewedConflict(
        compared.singleWhere((r) => r.entityType == _mesures),
        keepLocal: false,
      );
      expect(
        (await repository.fetchDossierById(_dossier))!.syncState,
        SyncState.conflict,
      );
      await repository.resolveReviewedConflict(
        compared.singleWhere((r) => r.entityType == _observations),
        keepLocal: false,
      );
      expect(
        (await repository.fetchDossierById(_dossier))!.syncState,
        SyncState.synced,
      );
    },
  );

  test('missing core server timestamps never become the local clock', () async {
    final raw =
        _core(dossierId: 'unversioned', patientId: 'unversioned-patient')
          ..remove('updatedAt')
          ..remove('createdAt')
          ..remove('workspaceUpdatedAt');
    (raw['patient'] as Map).remove('updatedAt');
    (raw['housing'] as Map).remove('updatedAt');
    await repository.mergeRemoteDossierPayloads([raw]);
    final dossierRow = (await db.query(
      'dossiers',
      where: 'local_id = ?',
      whereArgs: ['unversioned'],
    )).single;
    expect(dossierRow['remote_updated_at'], isNull);
    for (final (table, id) in [
      ('patients', dossierRow['patient_local_id']),
      ('housings', dossierRow['housing_local_id']),
    ]) {
      final stored = (await db.query(
        table,
        where: 'local_id = ?',
        whereArgs: [id],
      )).single;
      expect(stored['remote_updated_at'], isNull, reason: table);
      expect(
        stored['updated_at'],
        isNotNull,
        reason: 'Local bookkeeping remains',
      );
    }
    await repository.updatePatient('unversioned-patient', {
      'first_name': 'Edited',
    });
    expect(
      (await payload('patient'))['concurrency']['expectedUpdatedAt'],
      isNull,
    );
  });

  test(
    'an actual server creation timestamp remains a valid reference',
    () async {
      final raw =
          _core(dossierId: 'created-only', patientId: 'created-only-patient')
            ..remove('updatedAt')
            ..remove('workspaceUpdatedAt');
      for (final key in ['patient', 'housing']) {
        (raw[key] as Map)
          ..remove('updatedAt')
          ..['createdAt'] = _pulled;
      }
      await repository.mergeRemoteDossierPayloads([raw]);
      final dossierRow = (await db.query(
        'dossiers',
        where: 'local_id = ?',
        whereArgs: ['created-only'],
      )).single;
      expect(dossierRow['remote_updated_at'], _dossierVersion);
      for (final (table, id) in [
        ('patients', dossierRow['patient_local_id']),
        ('housings', dossierRow['housing_local_id']),
      ]) {
        expect(
          (await db.query(
            table,
            where: 'local_id = ?',
            whereArgs: [id],
          )).single['remote_updated_at'],
          _pulled,
        );
      }
    },
  );

  for (final type in _types) {
    group(type, () {
      test(
        'captures the pulled child version, not the dossier version',
        () async {
          expect((await db.query(type)).single['remote_updated_at'], _pulled);
          await edit(type, 1);
          final value = await payload(type);
          expect(value['concurrency']['version'], 1);
          expect(value['concurrency']['expectedUpdatedAt'], _pulled);
          expect(value['concurrency']['baseValues'], _patch(type, 0));
          expect(value['concurrency']['writeId'], matches(_uuidV4));
          expect(value['updates'], _patch(type, 1));
          expect(value.containsKey('localReference'), isFalse);
          expect(
            (await db.query('dossiers')).single['remote_updated_at'],
            _dossierVersion,
          );
        },
      );

      test(
        'retry preserves UUID; coalescing changes UUID but not baseline',
        () async {
          await edit(type, 1);
          final first = await payload(type);
          final runnable = (await queue.fetchRunnableOperations()).single;
          expect(await queue.tryMarkRunning(runnable), isTrue);
          expect(await payload(type), first);
          await db.update('dossiers', {'remote_updated_at': _reviewed});
          expect(
            await pull(type, _child(type, n: 9, version: _reviewed)),
            isFalse,
          );
          repository = DossierRepository(database: local);
          expect(await payload(type), first);
          await edit(type, 2);
          final next = await payload(type);
          expect(next['concurrency']['baseValues'], _patch(type, 0));
          expect(next['concurrency']['expectedUpdatedAt'], _pulled);
          expect(next['concurrency']['writeId'], matches(_uuidV4));
          expect(
            next['concurrency']['writeId'],
            isNot(first['concurrency']['writeId']),
          );
          expect(next['updates'], _patch(type, 2));
          expect((await db.query(type)).single['remote_updated_at'], _pulled);
        },
      );

      test(
        'old localReference remains legacy even with a newer stored version',
        () async {
          await pull(type, _child(type, version: null));
          await edit(type, 1);
          final first = await payload(type);
          expect(first.containsKey('concurrency'), isFalse);
          expect(first['localReference']['expectedUpdatedAt'], isNull);
          await db.update(type, {'remote_updated_at': _reviewed});
          await edit(type, 2);
          final next = await payload(type);
          expect(next.containsKey('concurrency'), isFalse);
          expect(next['localReference']['expectedUpdatedAt'], isNull);
          expect(next['localReference']['baseValues'], _patch(type, 0));
          expect(
            next['localReference']['writeId'],
            isNot(first['localReference']['writeId']),
          );
        },
      );

      test(
        'review is read-only and exposes only queued patch fields',
        () async {
          await edit(type, 1);
          await conflict(type);
          final before = await snapshot();
          final compared = await review(type);
          expect(compared.localValues, _patch(type, 1));
          expect(compared.remoteValues, _patch(type, 9));
          expect(compared.remoteUpdatedAt, _reviewed);
          expect(compared.entityLocalId, _dossier);
          expect(compared.table, type);
          expect(await snapshot(), before);
        },
      );

      test(
        'take remote changes only reviewed columns and retains other entities',
        () async {
          await edit(type, 1);
          await conflict(type);
          final before = await snapshot();
          final raw = _child(type, n: 9, version: _reviewed);
          if (type == _mesures) {
            raw['deboutHauteurCoude'] = 123.0;
          }
          if (type == _observations) {
            raw['observationEquipements'] = 'remote-only';
          }
          final compared = (await repository.reviewSecondaryConflicts(
            _dossier,
            {type: raw},
          )).single;
          await repository.resolveReviewedConflict(compared, keepLocal: false);
          final after = await snapshot();
          for (final table in ['dossiers', 'patients', 'housings', ..._types]) {
            if (table != type) {
              expect(after[table], before[table], reason: table);
            }
          }
          final expected = Map<String, Object?>.of(before[type]!.single)
            ..addAll(compared.remoteColumns)
            ..['remote_updated_at'] = _reviewed
            ..['sync_state'] = 'synced'
            ..remove('updated_at');
          final actual = Map<String, Object?>.of(after[type]!.single)
            ..remove('updated_at');
          expect(actual, expected);
          expect((await operation(type))['status'], 'completed');
          expect(await queue.fetchRunnableOperations(), isEmpty);
        },
      );

      test(
        'keep local creates a fresh guarded retry and persists vault history',
        () async {
          await edit(type, 1);
          await conflict(type);
          final original = await payload(type);
          final compared = await review(type);
          await repository.resolveReviewedConflict(compared, keepLocal: true);
          repository = DossierRepository(database: local);
          queue = SyncRepository.forTesting(database: local);
          final value = await payload(type);
          expect(value['updates'], _patch(type, 1));
          expect(value['concurrency']['baseValues'], _patch(type, 9));
          expect(value['concurrency']['expectedUpdatedAt'], _reviewed);
          expect(value['concurrency']['writeId'], matches(_uuidV4));
          expect(
            value['concurrency']['writeId'],
            isNot(original['concurrency']['writeId']),
          );
          expect(value.containsKey('conflict'), isFalse);
          expect(value.containsKey('localReference'), isFalse);
          expect((await db.query(type)).single['sync_state'], 'pendingSync');
          expect((await operation(type))['attempt_count'], 0);
          expect((await operation(type))['last_error'], isNull);
          expect(
            (await queue.fetchRunnableOperations()).single.entityType,
            type,
          );
          final history = (await db.query('sync_conflict_history')).single;
          // Native OfflineVault delegates encryption to SQLCipher; exercise its
          // persistence contract without claiming FFI SQLite encrypts the bytes.
          final archived = jsonDecode(
            await OfflineVault.instance.openString(
              history['snapshot_json'] as String,
            ),
          );
          expect(history['decision'], 'keep_local');
          expect(history['entity_type'], type);
          expect(archived['mutation'], original);
          expect(archived['remoteValues'], _patch(type, 9));
          expect(archived['remoteUpdatedAt'], _reviewed);
          final after = await snapshot();
          await expectLater(
            repository.resolveReviewedConflict(compared, keepLocal: true),
            throwsStateError,
          );
          expect(
            await snapshot(),
            after,
            reason: 'A decision cannot be replayed',
          );
        },
      );

      test('absent server row permits only guarded local creation', () async {
        await edit(type, 1);
        await conflict(type);
        final before = await snapshot();
        final compared = (await repository.reviewSecondaryConflicts(_dossier, {
          type: null,
        })).single;
        expect(compared.remoteExists, isFalse);
        expect(compared.remoteUpdatedAt, isNull);
        expect(compared.remoteValues.keys, _patch(type, 1).keys);
        expect(await snapshot(), before);
        await expectLater(
          repository.resolveReviewedConflict(compared, keepLocal: false),
          throwsStateError,
        );
        expect(await snapshot(), before);
        await repository.resolveReviewedConflict(compared, keepLocal: true);
        final retry = await payload(type);
        expect(retry['concurrency']['createIfAbsent'], isTrue);
        expect(retry['concurrency']['expectedUpdatedAt'], isNull);
        expect(retry['concurrency']['baseValues'], isEmpty);
        expect((await operation(type))['status'], 'pending');
      });

      for (final keepLocal in [false, true]) {
        test(
          'a new edit invalidates a stale keepLocal=$keepLocal review',
          () async {
            await edit(type, 1);
            await conflict(type);
            final compared = await review(type);
            await edit(type, 2);
            final before = await snapshot();
            await expectLater(
              repository.resolveReviewedConflict(
                compared,
                keepLocal: keepLocal,
              ),
              throwsStateError,
            );
            expect(await snapshot(), before);
            expect((await payload(type))['updates'], _patch(type, 2));
            expect((await operation(type))['status'], 'conflict');
            expect(await queue.fetchRunnableOperations(), isEmpty);
            expect(await db.query('sync_conflict_history'), isEmpty);
          },
        );
      }

      for (final invalid in [
        'missing entry',
        'wrong dossier',
        'missing version',
        'invalid version',
        'missing patch field',
      ]) {
        test('rejects $invalid without modifying any stored data', () async {
          await edit(type, 1);
          await conflict(type);
          final raw = _child(type, n: 9, version: _reviewed);
          switch (invalid) {
            case 'wrong dossier':
              raw['dossierId'] = 'another-dossier';
            case 'missing version':
              raw.remove('updatedAt');
            case 'invalid version':
              raw['updatedAt'] = 'not-a-date';
            case 'missing patch field':
              raw.remove(_patch(type, 1).keys.first);
          }
          final input = <String, Map<String, dynamic>?>{
            if (invalid != 'missing entry')
              type: invalid == 'null entry' ? null : raw,
          };
          final before = await snapshot();
          await expectLater(
            repository.reviewSecondaryConflicts(_dossier, input),
            throwsStateError,
          );
          expect(await snapshot(), before);
        });
      }
    });
  }

  test(
    'coalescing adds a newly edited scalar with its original baseline',
    () async {
      await edit(_mesures, 1);
      await repository.upsertMesures(
        _dossier,
        MesuresAnthropometriques(
          dossierId: _dossier,
          deboutHauteurCoude: 92,
          assisHauteurAssise: 45,
          observations: 'measure-2',
        ),
      );
      final value = await payload(_mesures);
      expect(value['updates'], {
        'observations': 'measure-2',
        'deboutHauteurCoude': 92,
      });
      expect(value['concurrency']['baseValues'], {
        'observations': 'measure-0',
        'deboutHauteurCoude': 90,
      });
      expect(value['concurrency']['expectedUpdatedAt'], _pulled);
    },
  );

  for (final faulty in [12, <String, dynamic>{}, <dynamic>[]]) {
    test('rejects non-text observation ${faulty.runtimeType}', () async {
      await edit(_observations, 1);
      await conflict(_observations);
      final raw = _child(_observations, n: 9, version: _reviewed)
        ..['projetSouhaitUsage'] = faulty;
      final before = await snapshot();
      await expectLater(
        repository.reviewSecondaryConflicts(_dossier, {_observations: raw}),
        throwsStateError,
      );
      expect(await snapshot(), before);
    });
  }

  for (final faulty in [
    '91',
    double.nan,
    double.infinity,
    <String, dynamic>{},
  ]) {
    test('rejects invalid measurement $faulty', () async {
      await repository.upsertMesures(
        _dossier,
        MesuresAnthropometriques(
          dossierId: _dossier,
          deboutHauteurCoude: 91,
          assisHauteurAssise: 45,
          observations: 'measure-0',
        ),
      );
      await conflict(_mesures);
      final raw = _child(_mesures, version: _reviewed)
        ..['deboutHauteurCoude'] = faulty;
      final before = await snapshot();
      await expectLater(
        repository.reviewSecondaryConflicts(_dossier, {_mesures: raw}),
        throwsStateError,
      );
      expect(await snapshot(), before);
    });
  }

  test('explicit null is distinct from an absent remote scalar', () async {
    await edit(_observations, 1);
    await conflict(_observations);
    final raw = _child(_observations, version: _reviewed)
      ..['projetSouhaitUsage'] = null;
    final compared = (await repository.reviewSecondaryConflicts(_dossier, {
      _observations: raw,
    })).single;
    expect(compared.remoteValues, {'projetSouhaitUsage': null});
    await repository.resolveReviewedConflict(compared, keepLocal: false);
    expect((await db.query(_observations)).single['projet_souhait_usage'], '');
  });

  test(
    'fictitious WC and bathroom edits retain a reviewed server baseline',
    () async {
      await edit(_diagnostic, 1);
      await conflict(_diagnostic);
      final server = _child(_diagnostic, n: 9, version: _reviewed);
      final compared = (await repository.reviewSecondaryConflicts(_dossier, {
        _diagnostic: server,
      })).single;
      await repository.resolveReviewedConflict(compared, keepLocal: false);
      // A just-resolved row is read from SQLite on reopening. The brief
      // read-replica guard deliberately rejects a fresh remote pull.
      expect(await pull(_diagnostic, server), isFalse);

      expect(
        (await repository.fetchDiagnosticSanitaire(
          _dossier,
        ))!.sdbInstances.first.id,
        'bath-9',
      );
      await edit(_diagnostic, 2);
      final next = await payload(_diagnostic);
      expect((await operation(_diagnostic))['status'], 'pending');
      expect(next['concurrency']['expectedUpdatedAt'], _reviewed);
      expect(
        next['concurrency']['baseValues']['sdbInstances'],
        server['sdbInstances'],
      );
      expect(
        next['concurrency']['baseValues']['wcInstances'],
        server['wcInstances'],
      );
    },
  );

  for (final faulty in [
    null,
    '[]',
    [1],
    <String, dynamic>{},
  ]) {
    test('rejects malformed diagnostic array $faulty', () async {
      await edit(_diagnostic, 1);
      await conflict(_diagnostic);
      final raw = _child(_diagnostic, version: _reviewed)
        ..['sdbInstances'] = faulty;
      final before = await snapshot();
      await expectLater(
        repository.reviewSecondaryConflicts(_dossier, {_diagnostic: raw}),
        throwsStateError,
      );
      expect(await snapshot(), before);
    });
  }

  for (final keepLocal in [false, true]) {
    test(
      'legacy diagnostic root lists resolve atomically, keepLocal=$keepLocal',
      () async {
        await edit(_diagnostic, 1);
        await conflict(_diagnostic);
        final old = await payload(_diagnostic);
        await replacePayload(_diagnostic, {
          'dossierId': _dossier,
          ..._patch(_diagnostic, 1),
          'conflict': old['conflict'],
        });
        final raw = _child(_diagnostic, n: 9, version: _reviewed);
        raw['sdbInstances'] = (raw['sdbInstances'] as List).reversed.toList();
        raw['wcInstances'] = <dynamic>[];
        final compared = (await repository.reviewSecondaryConflicts(_dossier, {
          _diagnostic: raw,
        })).single;
        expect(compared.localValues, _patch(_diagnostic, 1));
        await repository.resolveReviewedConflict(
          compared,
          keepLocal: keepLocal,
        );
        final value = await payload(_diagnostic);
        expect(value['sdbInstances'], value['updates']['sdbInstances']);
        expect(value['wcInstances'], value['updates']['wcInstances']);
        expect(value['concurrency']['baseValues'], compared.remoteValues);
        final stored = (await db.query(_diagnostic)).single;
        final expected = keepLocal
            ? _patch(_diagnostic, 1)
            : compared.remoteValues;
        expect(
          jsonDecode(stored['sdb_instances_json'] as String),
          expected['sdbInstances'],
        );
        expect(
          jsonDecode(stored['wc_instances_json'] as String),
          expected['wcInstances'],
        );
        expect(
          (await db.query('sync_conflict_history')).single['decision'],
          keepLocal ? 'keep_local' : 'take_remote',
        );
      },
    );
  }

  test(
    'incomplete legacy diagnostic cannot partially resolve one list',
    () async {
      await edit(_diagnostic, 1);
      await conflict(_diagnostic);
      await replacePayload(_diagnostic, {
        'dossierId': _dossier,
        'sdbInstances': _patch(_diagnostic, 1)['sdbInstances'],
      });
      final before = await snapshot();
      await expectLater(review(_diagnostic), throwsStateError);
      expect(await snapshot(), before);
    },
  );

  test(
    'unknown queued fields are rejected, not silently acknowledged',
    () async {
      await edit(_mesures, 1);
      await conflict(_mesures);
      final value = await payload(_mesures);
      (value['updates'] as Map)['unrecognizedField'] = 'local';
      await replacePayload(_mesures, value);
      final before = await snapshot();
      await expectLater(review(_mesures), throwsStateError);
      expect(await snapshot(), before);
    },
  );

  test(
    'another queued operation invalidates an otherwise unchanged review',
    () async {
      await edit(_mesures, 1);
      await conflict(_mesures);
      final compared = await review(_mesures);
      await db.insert('sync_operations', {
        ...await operation(_mesures),
        'id': 'competing-edit',
        'status': 'pending',
      });
      final before = await snapshot();
      await expectLater(
        repository.resolveReviewedConflict(compared, keepLocal: false),
        throwsStateError,
      );
      expect(await snapshot(), before);
    },
  );

  test(
    'SQLite failure rolls back child, queue and history as one transaction',
    () async {
      await edit(_mesures, 1);
      await conflict(_mesures);
      final compared = await review(_mesures);
      await db.execute(
        'CREATE TRIGGER fail_child_resolution BEFORE UPDATE ON '
        "$_mesures BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END",
      );
      final before = await snapshot();
      await expectLater(
        repository.resolveReviewedConflict(compared, keepLocal: false),
        throwsA(isA<DatabaseException>()),
      );
      expect(await snapshot(), before);
    },
  );

  test(
    'scope excludes pending edits and conflicts in other dossiers',
    () async {
      await edit(_mesures, 1);
      await conflict(_mesures);
      await edit(_observations, 1);
      await repository.mergeRemoteDossierPayloads([
        _core(),
        _core(dossierId: 'other-dossier', patientId: 'other-patient'),
      ]);
      await repository.updatePatient('other-patient', {
        'first_name': 'Other local',
      });
      await conflict('patient');
      final scope = await repository.conflictReviewScope(_dossier);
      expect(scope.remoteDossierId, _dossier);
      expect(scope.entityTypes, {_mesures});
      final before = await snapshot();
      await expectLater(
        repository.conflictReviewScope('missing'),
        throwsStateError,
      );
      expect(await snapshot(), before);
    },
  );

  test(
    'offline-created aliases are used by scope and core/secondary reviews',
    () async {
      final created = await repository.createDossierOffline(
        firstName: 'Offline',
        lastName: 'Synthetic',
      );
      final dossierId = created.id;
      final dossierRow = (await db.query(
        'dossiers',
        where: 'local_id = ?',
        whereArgs: [dossierId],
      )).single;
      final patientId = dossierRow['patient_local_id'] as String;
      await db.update(
        'sync_operations',
        {'status': 'completed'},
        where: 'entity_local_id = ?',
        whereArgs: [dossierId],
      );
      await db.update(
        'dossiers',
        {
          'remote_dossier_id': 'remote-created-dossier',
          'remote_updated_at': _pulled,
          'sync_state': 'synced',
        },
        where: 'local_id = ?',
        whereArgs: [dossierId],
      );
      await db.update(
        'patients',
        {
          'remote_patient_id': 'remote-created-patient',
          'remote_updated_at': _pulled,
          'sync_state': 'synced',
        },
        where: 'local_id = ?',
        whereArgs: [patientId],
      );
      await repository.updatePatient(patientId, {'first_name': 'Local alias'});
      await conflict('patient');
      await repository.mergeRemoteObservationsPayload(
        dossierId,
        _child(_observations, dossierId: 'remote-created-dossier'),
      );
      await edit(_observations, 1, dossierId: dossierId);
      await conflict(_observations);
      final scope = await repository.conflictReviewScope(dossierId);
      expect(scope.remoteDossierId, 'remote-created-dossier');
      expect(scope.entityTypes, {'patient', _observations});
      final raw = _core(
        dossierId: 'remote-created-dossier',
        patientId: 'remote-created-patient',
      );
      final coreReview = (await repository.reviewConflicts(
        dossierId,
        raw,
      )).single;
      expect(coreReview.localRowId, patientId);
      expect(coreReview.localValues, {'firstName': 'Local alias'});
      final childReview =
          (await repository.reviewSecondaryConflicts(dossierId, {
            _observations: _child(
              _observations,
              n: 9,
              dossierId: 'remote-created-dossier',
              version: _reviewed,
            ),
          })).single;
      expect(childReview.entityLocalId, dossierId);
      final before = await snapshot();
      await expectLater(
        repository.reviewConflicts(
          dossierId,
          _core(dossierId: dossierId, patientId: patientId),
        ),
        throwsStateError,
      );
      await expectLater(
        repository.reviewConflicts(
          dossierId,
          _core(dossierId: 'remote-created-dossier', patientId: patientId),
        ),
        throwsStateError,
      );
      await expectLater(
        repository.reviewSecondaryConflicts(dossierId, {
          _observations: _child(_observations, dossierId: dossierId),
        }),
        throwsStateError,
      );
      expect(await snapshot(), before);
      await repository.resolveReviewedConflict(childReview, keepLocal: false);
      expect(
        (await repository.fetchObservations(dossierId))!.projetSouhaitUsage,
        'project-9',
      );
      await repository.resolveReviewedConflict(coreReview, keepLocal: false);
      final storedPatient = (await db.query(
        'patients',
        where: 'local_id = ?',
        whereArgs: [patientId],
      )).single;
      expect(storedPatient['first_name'], 'Original');
      expect(storedPatient['remote_patient_id'], 'remote-created-patient');
    },
  );
}
