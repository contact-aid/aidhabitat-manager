import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _version = '2026-09-01T10:00:00.000Z';

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
      {
        'id': 'dossier-1',
        'createdAt': _version,
        'updatedAt': _version,
        'workspaceUpdatedAt': _version,
        'beneficiaryPrepared': false,
        'patient': {
          'id': 'patient-1',
          'firstName': 'Original',
          'lastName': 'Synthetic',
          'phone': '123',
          'updatedAt': _version,
        },
        'housing': {'surface': 80, 'updatedAt': _version},
      },
    ]);
  });
  tearDown(() async => db.close());

  Future<Map<String, dynamic>> operation(String type) async {
    final rows = await db.query(
      'sync_operations',
      where: 'entity_type = ?',
      whereArgs: [type],
    );
    return jsonDecode(
          await OfflineVault.instance.openString(
            rows.single['payload_json'] as String,
          ),
        )
        as Map<String, dynamic>;
  }

  test('patient save captures the reference before updating SQLite', () async {
    await repository.updatePatient('patient-1', {
      'first_name': 'Local',
      'last_name': 'Synthetic',
    });
    final op = await operation('patient');
    expect(op['updates'], {'firstName': 'Local'});
    expect(op['concurrency']['baseValues'], {'firstName': 'Original'});
    expect(op['concurrency']['expectedUpdatedAt'], _version);
    expect((await db.query('patients')).single['first_name'], 'Local');
  });

  test(
    'an intervening same-field pull preserves the draft as a conflict',
    () async {
      final opened = (await repository.fetchAllDossiers()).single;
      await db.update('patients', {'first_name': 'Remote'});
      await repository.updatePatient('patient-1', {
        'first_name': 'Draft',
      }, observedFields: opened.patientEditBaseline);
      final op = await operation('patient');
      expect(op['updates']['firstName'], 'Draft');
      expect(op['conflict']['fields']['first_name'], {
        'observed': 'Original',
        'current': 'Remote',
      });
      expect((await db.query('patients')).single['first_name'], 'Draft');
      expect((await db.query('sync_operations')).single['status'], 'conflict');
    },
  );

  test('an intervening unrelated field does not block the draft', () async {
    final opened = (await repository.fetchAllDossiers()).single;
    await db.update('patients', {'phone': '999'});
    await repository.updatePatient('patient-1', {
      'first_name': 'Draft',
    }, observedFields: opened.patientEditBaseline);
    expect((await operation('patient')).containsKey('conflict'), isFalse);
    expect((await db.query('patients')).single['phone'], '999');
  });

  test('administrative baseline uses the raw SQL field names', () async {
    final opened = (await repository.fetchAllDossiers()).single;
    expect(
      opened.dossierEditBaseline!.containsKey('personnes_presentes_visite'),
      isTrue,
    );
    await db.update('dossiers', {'personnes_presentes_visite': 'Remote'});
    await repository.updateDossierFields(opened.id, {
      'personnes_presentes_visite': 'Draft',
    }, observedFields: opened.dossierEditBaseline);
    expect(
      (await operation('dossier'))['conflict']['code'],
      'LOCAL_EDIT_BASE_CHANGED',
    );
  });

  test(
    'two queued saves preserve both edits and the original reference',
    () async {
      await Future.wait([
        repository.updatePatient('patient-1', {'first_name': 'Local'}),
        repository.updatePatient('patient-1', {'phone': '456'}),
      ]);
      final op = await operation('patient');
      expect(op['updates'], {'firstName': 'Local', 'phone': '456'});
      expect(op['concurrency']['baseValues'], {
        'firstName': 'Original',
        'phone': '123',
      });
      expect(op['concurrency']['expectedUpdatedAt'], _version);
    },
  );

  test(
    'a missing server timestamp is not replaced by the device clock',
    () async {
      await db.update('patients', {'remote_updated_at': null});
      await repository.updatePatient('patient-1', {'first_name': 'Local'});
      expect(
        (await operation('patient'))['concurrency']['expectedUpdatedAt'],
        isNull,
      );
    },
  );

  test('a malformed update object cannot be silently replaced', () async {
    await repository.updatePatient('patient-1', {'first_name': 'Local'});
    await db.update('sync_operations', {'payload_json': '{"updates":null}'});
    await expectLater(
      repository.updatePatient('patient-1', {'phone': '456'}),
      throwsFormatException,
    );
    expect((await db.query('patients')).single['phone'], '123');
    expect(
      (await db.query('sync_operations')).single['payload_json'],
      '{"updates":null}',
    );
  });

  for (final status in ['pending', 'running', 'failed', 'conflict']) {
    test(
      'a subsequent edit preserves the $status baseline and previous fields',
      () async {
        await repository.updatePatient('patient-1', {'first_name': 'Local'});
        await db.update('sync_operations', {'status': status});
        await db.update('patients', {
          'remote_updated_at': '2026-09-03T10:00:00.000Z',
        });
        await repository.updatePatient('patient-1', {
          'first_name': 'Local 2',
          'phone': '456',
        });
        final op = await operation('patient');
        expect(op['updates'], {'firstName': 'Local 2', 'phone': '456'});
        expect(op['concurrency']['baseValues'], {
          'firstName': 'Original',
          'phone': '123',
        });
        expect(op['concurrency']['expectedUpdatedAt'], _version);
      },
    );
  }

  test('completed mutation starts a fresh baseline', () async {
    await repository.updatePatient('patient-1', {'first_name': 'Local'});
    await db.update('sync_operations', {'status': 'completed'});
    const acknowledged = '2026-09-03T10:00:00.000Z';
    await db.update('patients', {'remote_updated_at': acknowledged});
    await repository.updatePatient('patient-1', {'first_name': 'Local 2'});
    final op = await operation('patient');
    expect(op['concurrency']['baseValues'], {'firstName': 'Local'});
    expect(op['concurrency']['expectedUpdatedAt'], acknowledged);
  });

  test(
    'old queue payloads stay unknown, not reconstructed from edited values',
    () async {
      await repository.updatePatient('patient-1', {'first_name': 'Local'});
      await db.update('sync_operations', {
        'payload_json': jsonEncode({
          'patientLocalId': 'patient-1',
          'updates': {'firstName': 'Local'},
        }),
      });
      await repository.updatePatient('patient-1', {'phone': '456'});
      final op = await operation('patient');
      expect(op['updates'], {'firstName': 'Local', 'phone': '456'});
      expect(op['concurrency']['baseValues'], {'phone': '123'});
      expect(op['concurrency']['expectedUpdatedAt'], isNull);
    },
  );

  test('dossier save captures its own server reference', () async {
    await repository.updateDossierFields('dossier-1', {
      'beneficiary_prepared': 1,
    });
    final op = await operation('dossier');
    expect(op['concurrency']['baseValues'], {'beneficiaryPrepared': 0});
    expect(op['concurrency']['expectedUpdatedAt'], _version);
  });

  test(
    'housing save captures its reference and complete room groups',
    () async {
      await db.update('housings', {
        'rdc_rooms_json': '["Kitchen"]',
        'floor_rooms_json': '["Bedroom"]',
      });
      await repository.updateHousing('dossier-1', {
        'surface': 90,
        'rdc_rooms_json': '["Kitchen","Bathroom"]',
      });
      final op = await operation('housing');
      expect(op['concurrency']['expectedUpdatedAt'], _version);
      expect(op['concurrency']['baseValues']['surface'], 80);
      expect(op['concurrency']['baseValues']['roomsBreakdown']['rdc'], [
        'Kitchen',
      ]);
      expect(op['concurrency']['baseValues']['roomsBreakdown']['floor'], [
        'Bedroom',
      ]);
      expect(op['updates']['roomsBreakdown']['floor'], ['Bedroom']);
    },
  );

  test('unchanged save leaves the captured operation untouched', () async {
    await repository.updatePatient('patient-1', {'first_name': 'Local'});
    final before = (await db.query('sync_operations')).single;
    await repository.updatePatient('patient-1', {'first_name': 'Local'});
    expect((await db.query('sync_operations')).single, before);
  });

  test(
    'an unreadable older payload rolls back the new save without losing either row',
    () async {
      await repository.updatePatient('patient-1', {'first_name': 'Local'});
      await db.update('sync_operations', {'payload_json': 'broken-json'});
      final before = (await db.query('patients')).single;
      await expectLater(
        repository.updatePatient('patient-1', {'phone': '456'}),
        throwsFormatException,
      );
      expect((await db.query('patients')).single, before);
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        'broken-json',
      );
    },
  );

  test('a failed queue insert rolls back both the value and baseline', () async {
    await repository.updatePatient('patient-1', {'first_name': 'Local'});
    final beforePatient = (await db.query('patients')).single;
    final beforeOp = (await db.query('sync_operations')).single;
    await db.execute(
      "CREATE TRIGGER reject_save BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'test failure'); END",
    );
    await expectLater(
      repository.updatePatient('patient-1', {'phone': '456'}),
      throwsA(isA<DatabaseException>()),
    );
    expect((await db.query('patients')).single, beforePatient);
    expect((await db.query('sync_operations')).single, beforeOp);
  });
}
