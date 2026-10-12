import 'dart:convert';
import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _version = '2026-10-01T10:00:00.000Z';
const _nextVersion = '2026-10-05T11:00:00.000Z';
const _dossierId = 'sanitary-sparse-fiction';
const _sparse = <String, dynamic>{
  'sdbInstances': [
    {'id': 'bath-fiction', 'levelField': 'rdc', 'sdbBaignoireHauteur': 42},
  ],
  'wcInstances': [
    {'id': 'wc-fiction', 'levelField': 'rdc'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final scenarios = <String, dynamic>{};
  tearDownAll(() async {
    final output = Platform.environment['SANITARY_FIXTURE_OUTPUT'];
    if (output == null) return;
    await File(output).writeAsString(
      '${const JsonEncoder.withIndent('  ').convert({
        'description': 'Fictitious payloads captured from real SQLite and DossierRepository. Only random writeId replaced for stable HTTP fixtures.',
        'source': {..._sparse, 'updatedAt': _version},
        'scenarios': scenarios,
      })}\n',
    );
  });

  for (final scenario in [
    'edit',
    'clear_direct',
    'clear_coalesced',
    'clear_after_ack',
  ]) {
    test('sparse SQLite DTO payload: $scenario', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repo = DossierRepository(database: local);
      expect(
        await repo.mergeRemoteDiagnosticSanitairePayload(_dossierId, {
          ..._sparse,
          'updatedAt': _version,
        }),
        isTrue,
      );
      final rowBefore = (await db.query('diagnostic_sanitaires')).single;
      expect(
        jsonDecode(rowBefore['sdb_instances_json'] as String),
        _sparse['sdbInstances'],
      );
      expect(
        jsonDecode(rowBefore['wc_instances_json'] as String),
        _sparse['wcInstances'],
      );
      final loaded = (await repo.fetchDiagnosticSanitaire(_dossierId))!;
      expect(await db.query('sync_operations'), isEmpty);
      expect((await db.query('diagnostic_sanitaires')).single, rowBefore);
      expect(loaded.sdbInstances.single.sdbBaignoire, isFalse);
      expect(loaded.wcInstances.single.wcCuvetteBonneHauteur, isTrue);
      expect(loaded.wcInstances.single.wcBarreRelevement, isNull);
      final edited = DiagnosticSanitaire(
        dossierId: _dossierId,
        sdbInstances: [
          BathroomInstance.fromJson({
            ...loaded.sdbInstances.single.toJson(),
            'sdbBacDouche': true,
            'sdbBacDoucheHauteur': 7,
          }),
        ],
        wcInstances: [
          WcInstance.fromJson({
            ...loaded.wcInstances.single.toJson(),
            'observationEquipementsUtilisation': 'Observation fictive',
          }),
        ],
      );
      var expectedBase = _sparse;
      var expectedVersion = _version;
      if (scenario != 'clear_direct') {
        await repo.upsertDiagnosticSanitaire(_dossierId, edited);
      }
      if (scenario == 'clear_after_ack') {
        // Only the synthetic database is acknowledged, never a real queue.
        await db.update('sync_operations', {
          'status': 'completed',
          'updated_at': _version,
        });
        await db.update('diagnostic_sanitaires', {
          'sync_state': 'synced',
          'remote_updated_at': _nextVersion,
        });
        expectedBase = {
          'sdbInstances': edited.sdbInstances.map((r) => r.toJson()).toList(),
          'wcInstances': edited.wcInstances.map((r) => r.toJson()).toList(),
        };
        expectedVersion = _nextVersion;
      }
      if (scenario != 'edit') {
        await repo.upsertDiagnosticSanitaire(
          _dossierId,
          const DiagnosticSanitaire(dossierId: _dossierId),
        );
      }
      final operation = (await db.query('sync_operations')).single;
      expect(operation['status'], 'pending');
      final payload =
          jsonDecode(
                await OfflineVault.instance.openString(
                  operation['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      final guard = payload['concurrency'] as Map<String, dynamic>;
      expect(guard['baseValues'], expectedBase);
      expect(guard['expectedUpdatedAt'], expectedVersion);
      expect(guard['collectionContract'], 'collections-v2');
      expect(payload['sdbInstances'], payload['updates']['sdbInstances']);
      expect(payload['wcInstances'], payload['updates']['wcInstances']);
      if (scenario == 'edit') {
        expect(
          payload['updates']['sdbInstances'],
          edited.sdbInstances.map((r) => r.toJson()).toList(),
        );
        expect(
          payload['updates']['wcInstances'],
          edited.wcInstances.map((r) => r.toJson()).toList(),
        );
        expect(
          (guard['baseValues']['wcInstances'] as List).single.containsKey(
            'wcCuvetteBonneHauteur',
          ),
          isFalse,
        );
      } else {
        expect(payload['updates'], {'sdbInstances': [], 'wcInstances': []});
      }
      scenarios[scenario] = {
        'updates': payload['updates'],
        'baseValues': guard['baseValues'],
        'expectedUpdatedAt': guard['expectedUpdatedAt'],
        'wireBody': {
          ...payload['updates'] as Map<String, dynamic>,
          'concurrency': {
            ...guard,
            'writeId': '10000000-0000-4000-8000-000000000001',
            if (guard.containsKey('predecessorWriteIds'))
              'predecessorWriteIds': <String>[],
          },
        },
      };
    });
  }
}
