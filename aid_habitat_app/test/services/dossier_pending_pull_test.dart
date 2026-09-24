import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _baseline = '2026-09-01T10:00:00.000Z';
const _newer = '2026-09-02T10:00:00.000Z';

Map<String, dynamic> _remote(String id, {bool newer = false}) => {
  'id': id,
  'status': 'A visiter',
  'createdAt': _baseline,
  'updatedAt': newer ? _newer : _baseline,
  'workspaceUpdatedAt': newer ? _newer : _baseline,
  'patient': {
    'id': 'patient-$id',
    'firstName': newer ? 'Remote new' : 'Original',
    'lastName': 'Synthetic',
    'updatedAt': newer ? _newer : _baseline,
  },
  'housing': {'updatedAt': newer ? _newer : _baseline},
  'autonomy': {'done': newer},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = DossierRepository(database: local);
    await repository.mergeRemoteDossierPayloads([
      _remote('one'),
      _remote('two'),
    ]);
  });

  tearDown(() async => db.close());

  Future<Map<String, Object?>> row(String table, String id) async =>
      (await db.query(table, where: 'local_id = ?', whereArgs: [id])).single;

  Future<void> enqueue(String type, String entityId, String status) async {
    await db.insert('sync_operations', {
      'id': 'op-one',
      'entity_type': type,
      'entity_local_id': entityId,
      'operation_type': 'update',
      'status': status,
      'payload_json': '{"updates":{"firstName":"Local edit"}}',
      'created_at': _baseline,
      'updated_at': _baseline,
      'last_error': status == 'failed' ? 'HTTP (422)' : null,
    });
  }

  for (final entity in {
    'patient': 'patient-one',
    'housing': 'one',
    'dossier': 'one',
    'contexte_de_vie': 'one',
  }.entries) {
    for (final status in ['pending', 'running', 'failed', 'conflict']) {
      test(
        '${entity.key}/$status keeps local data and server baseline',
        () async {
          // Deliberately leave sync_state=synced to simulate a stale UI state
          // or an acknowledgement racing with another local operation.
          await db.update(
            'patients',
            {'first_name': 'Local edit'},
            where: 'local_id = ?',
            whereArgs: ['patient-one'],
          );
          await enqueue(entity.key, entity.value, status);
          final beforePatient = await row('patients', 'patient-one');
          final beforeHousing = await row('housings', 'housing_one');
          final beforeDossier = await row('dossiers', 'one');
          final beforeOperation = (await db.query('sync_operations')).single;

          await repository.mergeRemoteDossierPayloads([
            _remote('one', newer: true),
            _remote('two', newer: true),
          ]);

          expect(await row('patients', 'patient-one'), beforePatient);
          expect(await row('housings', 'housing_one'), beforeHousing);
          expect(await row('dossiers', 'one'), beforeDossier);
          expect((await db.query('sync_operations')).single, beforeOperation);
          expect(
            (await row('patients', 'patient-two'))['first_name'],
            'Remote new',
          );
          final context = (await db.query(
            'contexte_de_vie',
            where: 'dossier_local_id = ?',
            whereArgs: ['one'],
          )).single;
          expect(jsonDecode(context['autonomy_json'] as String)['done'], false);
        },
      );
    }
  }

  test(
    'housing operations keyed by housing id also protect the bundle',
    () async {
      await enqueue('housing', 'housing_one', 'pending');
      await repository.mergeRemoteDossierPayloads([
        _remote('one', newer: true),
        _remote('two'),
      ]);
      expect((await row('patients', 'patient-one'))['first_name'], 'Original');
    },
  );

  test(
    'a newer remote value cannot replace an unacknowledged local patient edit',
    () async {
      await db.update(
        'patients',
        {'first_name': 'Local edit', 'sync_state': 'pendingSync'},
        where: 'local_id = ?',
        whereArgs: ['patient-one'],
      );
      await repository.mergeRemoteDossierPayloads([
        _remote('one', newer: true),
        _remote('two'),
      ]);
      expect(
        (await row('patients', 'patient-one'))['first_name'],
        'Local edit',
      );
      expect((await row('patients', 'patient-one'))['sync_state'], 'pendingSync');
      expect((await row('patients', 'patient-two'))['first_name'], 'Original');
    },
  );

  test('a newer remote value cannot replace an unacknowledged local dossier edit', () async {
    await db.update('dossiers', {'status': 'Local status', 'sync_state': 'pendingSync'},
        where: 'local_id = ?', whereArgs: ['one']);
    await repository.mergeRemoteDossierPayloads([_remote('one', newer: true)]);
    expect((await row('dossiers', 'one'))['status'], 'Local status');
    expect((await row('dossiers', 'one'))['sync_state'], 'pendingSync');
  });

  test('pull resumes after the outstanding write has completed', () async {
    await enqueue('patient', 'patient-one', 'pending');
    await repository.mergeRemoteDossierPayloads([
      _remote('one', newer: true),
      _remote('two'),
    ]);
    expect(
      (await row('patients', 'patient-one'))['remote_updated_at'],
      _baseline,
    );
    await db.update('sync_operations', {'status': 'completed'});
    await repository.mergeRemoteDossierPayloads([
      _remote('one', newer: true),
      _remote('two'),
    ]);
    expect((await row('patients', 'patient-one'))['first_name'], 'Remote new');
    expect((await row('patients', 'patient-one'))['remote_updated_at'], _newer);
  });

  test(
    'an absent remote dossier cannot delete an outstanding local bundle',
    () async {
      await enqueue('patient', 'patient-one', 'running');
      await repository.mergeRemoteDossierPayloads([
        _remote('two', newer: true),
      ]);
      expect(await row('dossiers', 'one'), isNotEmpty);
      expect(await row('patients', 'patient-one'), isNotEmpty);
      expect(await row('housings', 'housing_one'), isNotEmpty);
      expect((await db.query('sync_operations')).single['status'], 'running');

      // Once acknowledged, normal remote deletion reconciliation still works.
      await db.update('sync_operations', {'status': 'completed'});
      await repository.mergeRemoteDossierPayloads([
        _remote('two', newer: true),
      ]);
      expect(
        await db.query('dossiers', where: 'local_id = ?', whereArgs: ['one']),
        isEmpty,
      );
      expect(
        await db.query(
          'patients',
          where: 'local_id = ?',
          whereArgs: ['patient-one'],
        ),
        isEmpty,
      );
      expect(
        await db.query(
          'housings',
          where: 'local_id = ?',
          whereArgs: ['housing_one'],
        ),
        isEmpty,
      );
    },
  );

  test('an absent remote dossier preserves an unsynced patient and its bundle', () async {
    await db.update('patients', {'first_name': 'Local edit', 'sync_state': 'pendingSync'},
        where: 'local_id = ?', whereArgs: ['patient-one']);
    await repository.mergeRemoteDossierPayloads([_remote('two', newer: true)]);
    expect((await row('patients', 'patient-one'))['first_name'], 'Local edit');
    expect(await row('dossiers', 'one'), isNotEmpty);
    expect(await row('housings', 'housing_one'), isNotEmpty);
    expect(await db.query('sync_operations'), isEmpty);
  });

  test('unrelated entity types do not freeze dossier refresh', () async {
    await enqueue('document', 'one', 'pending');
    await repository.mergeRemoteDossierPayloads([
      _remote('one', newer: true),
      _remote('two'),
    ]);
    expect((await row('patients', 'patient-one'))['first_name'], 'Remote new');
  });

  test(
    'a changed remote patient link cannot purge the protected local patient',
    () async {
      await enqueue('dossier', 'one', 'pending');
      final incoming = _remote('one', newer: true);
      (incoming['patient'] as Map<String, dynamic>)['id'] =
          'replacement-patient';
      await repository.mergeRemoteDossierPayloads([incoming, _remote('two')]);
      expect((await row('dossiers', 'one'))['patient_local_id'], 'patient-one');
      expect(await row('patients', 'patient-one'), isNotEmpty);
      expect(
        await db.query(
          'patients',
          where: 'local_id = ?',
          whereArgs: ['replacement-patient'],
        ),
        isEmpty,
      );
    },
  );

  test('protection survives reopening the repository', () async {
    await enqueue('patient', 'patient-one', 'pending');
    final reopened = DossierRepository(database: LocalDatabase.forTesting(db));
    await reopened.mergeRemoteDossierPayloads([
      _remote('one', newer: true),
      _remote('two'),
    ]);
    expect((await row('patients', 'patient-one'))['first_name'], 'Original');
    expect(
      (await row('patients', 'patient-one'))['remote_updated_at'],
      _baseline,
    );
    expect((await db.query('sync_operations')).single['status'], 'pending');
  });

  test(
    'child-table conflict protects values even with a stale synced state',
    () async {
      await repository.mergeRemoteObservationsPayload('one', {
        'projetSouhaitUsage': 'Local project',
      });
      await enqueue('observations_synthese', 'one', 'conflict');
      expect(
        await repository.mergeRemoteObservationsPayload('one', {
          'projetSouhaitUsage': 'Remote project',
        }),
        false,
      );
      expect(
        (await db.query(
          'observations_synthese',
        )).single['projet_souhait_usage'],
        'Local project',
      );
    },
  );
}
