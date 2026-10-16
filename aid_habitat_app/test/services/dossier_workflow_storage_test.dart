import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/dossier_workflow.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'workflow fields survive offline storage and a later sending-date clear',
    () async {
      final database = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
      );
      addTearDown(database.close);
      final local = LocalDatabase.forTesting(database);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      Map<String, dynamic> payload(String sent, String revision) => {
        'id': 'airtable:synthetic',
        'status': 'À visiter',
        'ergoId': 'Coralie',
        'visitDate': '2026-10-15',
        'airtableStage': '2. Envoi du dossier',
        'airtableReportSentDate': sent,
        'createdAt': '2026-10-01',
        'updatedAt': revision,
        'workspaceUpdatedAt': revision,
        'patient': {
          'id': 'synthetic',
          'firstName': 'Camille',
          'lastName': 'Exemple',
        },
        'housing': <String, dynamic>{},
      };
      await repository.mergeRemoteDossierPayloads([
        payload('2026-10-16', 'revision-1'),
      ]);
      final sent = (await repository.fetchAllDossiers()).single;
      expect(sent.airtableStage, '2. Envoi du dossier');
      expect(sent.airtableReportSentDate, '2026-10-16');
      expect(dossierBucket(sent), DossierBucket.rapportEnvoye);
      await repository.mergeRemoteDossierPayloads([payload('', 'revision-2')]);
      final cleared = (await repository.fetchAllDossiers()).single;
      expect(cleared.airtableReportSentDate, '');
      expect(
        dossierBucket(cleared, now: DateTime.utc(2026, 10, 16, 12)),
        DossierBucket.rapportAFaire,
      );
    },
  );

  test('schema 26 upgrades without losing existing dossiers', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    final local = LocalDatabase.forTesting(database);
    await local.createSchemaForTesting();
    final repository = DossierRepository(database: local);
    await repository.createDossierOffline(
      firstName: 'Camille',
      lastName: 'Exemple',
    );
    await database.execute('ALTER TABLE dossiers DROP COLUMN airtable_stage');
    await database.execute(
      'ALTER TABLE dossiers DROP COLUMN airtable_report_sent_date',
    );
    await local.upgradeSchemaForTesting(26);
    final rows = await database.query('dossiers');
    expect(rows, hasLength(1));
    expect(rows.single['airtable_stage'], isNull);
    expect(rows.single['airtable_report_sent_date'], isNull);
  });
}
