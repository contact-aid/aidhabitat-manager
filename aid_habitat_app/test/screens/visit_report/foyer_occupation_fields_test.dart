import 'dart:convert';

import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/beneficiary_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _version = '2026-09-01T10:00:00.000Z';

Finder _textField(String label) => find.byWidgetPredicate(
  (widget) => widget is FormTextField && widget.label == label,
);

Finder _warningField(String label) => find.byWidgetPredicate(
  (widget) => widget is FormTextFieldWithWarning && widget.label == label,
);

Finder _reportField() => find.byWidgetPredicate(
  (widget) =>
      widget is FormMultiToggleGroup && widget.label == 'Envoi du rapport',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets(
    'existing values move to Foyer and edits queue offline unchanged',
    (tester) async {
      late Database db;
      late DossierRepository repository;
      late Dossier dossier;
      await tester.runAsync(() async {
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
            'patient': {
              'id': 'patient-1',
              'firstName': 'Anne',
              'lastName': 'EXEMPLE',
              'birthDate': '',
              'trustedPerson': {
                'name': 'Marie',
                'phone': '0611111111',
                'email': 'avant@example.fr',
              },
              'updatedAt': _version,
            },
            'housing': {'updatedAt': _version},
            'personnesPresentesVisite': 'Son fils',
            'envoiRapport': 'Mail',
          },
        ]);
        dossier = (await repository.fetchAllDossiers()).single;
      });
      addTearDown(() async => db.close());
      final controller = BeneficiaryTabController();
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Future<void> show(Dossier value, int section) async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BeneficiaryTab(
                dossier: value,
                repository: repository,
                controller: controller,
                initialSubSection: section,
              ),
            ),
          ),
        );
        await tester.pump();
      }

      await show(dossier, 1);
      expect(
        tester
            .widget<FormTextField>(
              _textField('Personnes présentes à la visite'),
            )
            .value,
        'Son fils',
      );
      expect(
        tester
            .widget<FormTextFieldWithWarning>(
              _warningField('Téléphone de la personne de confiance'),
            )
            .value,
        '0611111111',
      );
      expect(
        tester
            .widget<FormTextFieldWithWarning>(
              _warningField('Email de la personne de confiance'),
            )
            .value,
        'avant@example.fr',
      );
      expect(tester.widget<FormMultiToggleGroup>(_reportField()).selected, {
        'Mail',
      });

      tester
          .widget<FormTextField>(_textField('Personnes présentes à la visite'))
          .onChanged!('Sa fille');
      tester
          .widget<FormTextFieldWithWarning>(
            _warningField('Téléphone de la personne de confiance'),
          )
          .onChanged!('0622222222');
      tester
          .widget<FormTextFieldWithWarning>(
            _warningField('Email de la personne de confiance'),
          )
          .onChanged!('apres@example.fr');
      tester.widget<FormMultiToggleGroup>(_reportField()).onChanged!({
        'Mail',
        'Courrier',
      });
      await tester.pump();
      await tester.runAsync(controller.flushPendingSave);
      await tester.pump();

      late Map<String, Object?> storedPatient;
      late Map<String, Object?> storedDossier;
      late List<Map<String, Object?>> operations;
      final updates = <String, Map<String, dynamic>>{};
      late Dossier reloaded;
      await tester.runAsync(() async {
        storedPatient = (await db.query('patients')).single;
        storedDossier = (await db.query('dossiers')).single;
        operations = await db.query('sync_operations');
        for (final row in operations) {
          updates[row['entity_type'] as String] =
              jsonDecode(
                    await OfflineVault.instance.openString(
                      row['payload_json'] as String,
                    ),
                  )
                  as Map<String, dynamic>;
        }
        reloaded = (await repository.fetchAllDossiers()).single;
      });
      final trusted =
          jsonDecode(storedPatient['trusted_person_json'] as String)
              as Map<String, dynamic>;
      expect(trusted, {
        'name': 'Marie',
        'phone': '0622222222',
        'email': 'apres@example.fr',
      });
      expect(storedDossier['personnes_presentes_visite'], 'Sa fille');
      expect(storedDossier['envoi_rapport'], 'Mail, Courrier');

      expect(operations, hasLength(2));
      expect(operations.map((row) => row['status']), everyElement('pending'));
      expect(
        updates['patient']?['updates'],
        containsPair('trustedPerson', trusted),
      );
      expect(
        updates['dossier']?['updates'],
        containsPair('envoiRapport', 'Mail, Courrier'),
      );
      expect(
        updates['dossier']?['updates'],
        containsPair('personnesPresentesVisite', 'Sa fille'),
      );

      await show(reloaded, 1);
      expect(
        tester
            .widget<FormTextField>(
              _textField('Personnes présentes à la visite'),
            )
            .value,
        'Sa fille',
      );
      expect(
        tester
            .widget<FormTextFieldWithWarning>(
              _warningField('Téléphone de la personne de confiance'),
            )
            .value,
        '0622222222',
      );
      expect(
        tester
            .widget<FormTextFieldWithWarning>(
              _warningField('Email de la personne de confiance'),
            )
            .value,
        'apres@example.fr',
      );
      expect(tester.widget<FormMultiToggleGroup>(_reportField()).selected, {
        'Mail',
        'Courrier',
      });

      await show(reloaded, 2);
      expect(_textField('Personnes présentes à la visite'), findsNothing);
      await show(reloaded, 3);
      expect(
        _warningField('Téléphone de la personne de confiance'),
        findsNothing,
      );
      expect(_warningField('Email de la personne de confiance'), findsNothing);
      expect(_reportField(), findsNothing);
    },
  );
}
