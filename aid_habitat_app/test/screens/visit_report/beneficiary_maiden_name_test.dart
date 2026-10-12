import 'dart:convert';

import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/beneficiary_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository extends Fake implements DossierRepository {
  final patientWrites = <Map<String, dynamic>>[];

  @override
  Future<void> updatePatient(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async {
    patientWrites.add(fields);
  }
}

Dossier _dossier(String gender) => Dossier(
  id: 'synthetic-dossier',
  patient: Patient(
    id: 'synthetic-patient',
    firstName: 'Camille',
    lastName: 'Exemple',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    occupants: [Occupant(firstName: 'Camille', lastName: 'Exemple', gender: gender)],
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.TO_VISIT,
  ergoId: 'synthetic-ergo',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
  createdAt: '2026-09-30',
);

void main() {
  testWidgets('a female occupant can save a maiden name above her birth date', (
    tester,
  ) async {
    final repository = _Repository();
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BeneficiaryTab(
        dossier: _dossier('Femme'),
        repository: repository,
      )),
    ));
    await tester.pump();

    final maidenField = find.byWidgetPredicate(
      (widget) => widget is FormTextField && widget.label == 'Nom de jeune fille',
    );
    expect(maidenField, findsOneWidget);
    expect(
      tester.getTopLeft(maidenField).dy,
      lessThan(tester.getTopLeft(find.text('Date de naissance').first).dy),
    );
    await tester.enterText(
      find.descendant(of: maidenField, matching: find.byType(TextFormField)),
      'Martin',
    );
    await tester.pump(kSaveDebounceText);
    await tester.pump();
    expect(repository.patientWrites, isNotEmpty);
    final saved = jsonDecode(repository.patientWrites.last['occupants_json'] as String)
        as List<dynamic>;
    expect(saved.first['maidenName'], 'Martin');
  });

  testWidgets('the maiden name field is hidden for a male occupant', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: BeneficiaryTab(
        dossier: _dossier('Homme'),
        repository: _Repository(),
      )),
    ));
    await tester.pump();
    expect(find.text('Nom de jeune fille'), findsNothing);
  });
}
