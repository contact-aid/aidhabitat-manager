// Characterization of the UNMODIFIED build 64. Passing tests demonstrate blockers,
// not successful compatibility. Run tools/test-build64-occupants.sh.
import 'dart:convert';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/beneficiary_tab.dart';
import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Repository extends Fake implements DossierRepository {
  final writes = <Map<String, dynamic>>[];
  @override
  Future<void> updatePatient(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async => writes.add(Map.of(fields));
}

Map<String, dynamic> person(String firstName) => {
  'firstName': firstName,
  'lastName': 'Fictif',
  'gender': 'Femme',
  'maidenName': 'Naissance fictive',
  'birthDate': '1960-01-01',
};
Dossier fixture(int count) => Dossier(
  id: 'fictional-dossier',
  patient: Patient(
    id: 'fictional-patient',
    firstName: 'Alice',
    lastName: 'Fictif',
    birthDate: '1960-01-01',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    numberPeople: count,
    occupants: [
      'Alice',
      'Bob',
      'Charlie',
    ].map((n) => Occupant.fromJson(person(n))).toList(),
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.TO_VISIT,
  ergoId: '',
  createdAt: '2026-10-01',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
);
void main() {
  test(
    'BLOCKER: exact64 drops unknown civility and maidenName on roundtrip',
    () {
      final saved = Occupant.fromJson(
        person('Alice'),
      ).copyWith(homeHelp: true).toJson();
      expect(saved.containsKey('gender'), isFalse);
      expect(saved.containsKey('maidenName'), isFalse);
      expect(saved['homeHelp'], isTrue);
    },
  );
  for (final count in [2, 3]) {
    testWidgets(
      'exact64 health edit emits $count rows for three stored occupants',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 1600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = Repository();
        final controller = BeneficiaryTabController();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BeneficiaryTab(
                dossier: fixture(count),
                repository: repository,
                controller: controller,
                initialSubSection: 2,
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          repository.writes,
          isEmpty,
          reason: 'Loading itself must not save',
        );
        final field = find.byWidgetPredicate(
          (w) => w is FormToggleGroup && w.label == 'Aide à domicile',
        );
        expect(field, findsOneWidget);
        tester.widget<FormToggleGroup>(field).onChanged!('Oui');
        await tester.pump(kSaveDebounceText);
        await controller.flushPendingSave();
        await tester.pump();
        expect(repository.writes, isNotEmpty);
        final serialized = repository.writes.last['occupants_json'] as String;
        final rows = jsonDecode(serialized) as List;
        expect(rows, hasLength(count));
        expect(
          rows.any((o) => o['firstName'] == 'Charlie'),
          count == 3,
          reason: count == 2
              ? 'BLOCKER: lower/stale count deletes third identity'
              : 'Matching count survives',
        );
        expect(
          rows.every(
            (o) => !o.containsKey('gender') && !o.containsKey('maidenName'),
          ),
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
