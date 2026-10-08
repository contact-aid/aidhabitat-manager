import 'dart:convert';
import 'package:aid_habitat_app/models/dossier_occupants.dart';
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
    'display/reopen preserves original SQL and unrelated offline queue never converts names',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repo = DossierRepository(database: local);
      await repo.mergeRemoteDossierPayloads([
        {
          'id': 'fictional-dossier',
          'updatedAt': '2026-10-01T00:00:00Z',
          'patient': {
            'id': 'fictional-patient',
            'firstName': 'Alice et Bob',
            'lastName': 'Fictif',
            'numberPeople': 2,
            'occupants': [
              {
                'firstName': 'Alice et Bob',
                'lastName': 'Fictif',
                'maidenName': '',
                'gender': '',
                'homeHelpTxt': 'Texte à conserver',
              },
              {'firstName': '', 'lastName': '', 'homeHelpTxt': 'Autre texte'},
            ],
          },
          'housing': {},
        },
      ]);
      final before = (await db.query('patients')).single['occupants_json'];
      for (var i = 0; i < 2; i++) {
        final dossier = (await repo.fetchAllDossiers()).single;
        expect(dossierOccupants(dossier.patient).map((o) => o.firstName), [
          'Alice',
          'Bob',
        ]);
        expect(dossier.patient.occupants.first.maidenName, '');
        expect(dossier.patient.occupants.first.gender, '');
      }
      expect(await db.query('sync_operations'), isEmpty);
      expect((await db.query('patients')).single['occupants_json'], before);
      await repo.updatePatient('fictional-patient', {'phone': '0100000000'});
      final op = (await db.query('sync_operations')).single;
      final body = jsonDecode(
        await OfflineVault.instance.openString(op['payload_json'] as String),
      );
      expect(body['updates'], {'phone': '0100000000'});
      expect((await db.query('patients')).single['occupants_json'], before);
      final raw = (jsonDecode(before as String) as List).first;
      final saved = Occupant.fromJson(
        Map<String, dynamic>.from(raw),
      ).copyWith(homeHelp: true).toJson();
      expect(saved['maidenName'], '');
      expect(saved['gender'], '');
      expect(saved['homeHelpTxt'], 'Texte à conserver');
    },
  );
}
