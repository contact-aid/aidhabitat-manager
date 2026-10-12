import 'dart:convert';
import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'SQLite reopen preserves IDs, order, measurements and observations; queue exposes full-array deletion',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'assist2-sanitary-synthetic-',
      );
      Database? db;
      try {
        final path = '${dir.path}/fixture.db';
        db = await databaseFactoryFfi.openDatabase(path);
        var local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        var repo = DossierRepository(database: local);
        final original = DiagnosticSanitaire(
          dossierId: 'synthetic-only',
          sdbInstances: [
            for (var i = 0; i < 3; i++)
              BathroomInstance(
                id: 'stable-bath-$i',
                levelField: i == 2 ? 'floor' : 'rdc',
                levelLabel: 'Custom $i',
                sdbBaignoire: true,
                sdbBaignoireHauteur: 41 + i.toDouble(),
                porteSdbDimension: 70 + i.toDouble(),
              ),
          ],
          wcInstances: [
            for (var i = 0; i < 3; i++)
              WcInstance(
                id: 'stable-wc-$i',
                levelField: i == 2 ? 'floor' : 'rdc',
                wcCuvetteHauteur: 44 + i.toDouble(),
                wcBarreRelevement: i == 1,
                observationEquipementsUtilisation: 'Fictif observation $i',
              ),
          ],
        );
        await repo.upsertDiagnosticSanitaire('synthetic-only', original);
        // Simulate an acknowledged baseline before the next offline mutation.
        await db.delete('sync_operations');
        await db.update('diagnostic_sanitaires', {
          'remote_updated_at': '2026-09-01T10:00:00Z',
          'sync_state': 'synced',
        });
        await db.close();
        db = await databaseFactoryFfi.openDatabase(path);
        local = LocalDatabase.forTesting(db);
        repo = DossierRepository(database: local);
        final reopened = (await repo.fetchDiagnosticSanitaire(
          'synthetic-only',
        ))!;
        expect(
          reopened.sdbInstances.map((r) => r.toJson()).toList(),
          original.sdbInstances.map((r) => r.toJson()).toList(),
        );
        expect(
          reopened.wcInstances.map((r) => r.toJson()).toList(),
          original.wcInstances.map((r) => r.toJson()).toList(),
        );
        // Exact64 tabs pass a reduced list after hydration. Repository faithfully
        // persists that list; it cannot infer whether omission was intentional.
        await repo.upsertDiagnosticSanitaire(
          'synthetic-only',
          DiagnosticSanitaire(
            dossierId: 'synthetic-only',
            sdbInstances: [
              reopened.sdbInstances.first,
              reopened.sdbInstances.last,
            ],
            wcInstances: reopened.wcInstances,
          ),
        );
        final rows = await db.query(
          'sync_operations',
          where: 'entity_type = ?',
          whereArgs: ['diagnostic_sanitaires'],
        );
        final payload =
            jsonDecode(
                  await OfflineVault.instance.openString(
                    rows.single['payload_json'] as String,
                  ),
                )
                as Map<String, dynamic>;
        expect((payload['updates']['sdbInstances'] as List).length, 2);
        expect(
          (payload['concurrency']['baseValues']['sdbInstances'] as List).length,
          3,
        );
        final saved = (await repo.fetchDiagnosticSanitaire('synthetic-only'))!;
        expect(saved.sdbInstances.map((r) => r.id), [
          'stable-bath-0',
          'stable-bath-2',
        ]);
        expect(
          saved.wcInstances.map((r) => r.toJson()).toList(),
          original.wcInstances.map((r) => r.toJson()).toList(),
        );
      } finally {
        if (db?.isOpen ?? false) await db!.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
