import 'dart:async';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/bathroom_tab.dart';
import 'package:aid_habitat_app/screens/visit_report/wc_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DelayedHousingRepository extends DossierRepository {
  final firstRead = Completer<Map<String, dynamic>?>();
  int reads = 0;

  @override
  Future<DiagnosticSanitaire?> fetchDiagnosticSanitaire(
    String dossierId,
  ) async => null;

  @override
  Future<Map<String, dynamic>?> fetchHousingRaw(String dossierId) {
    reads++;
    if (reads == 1) return firstRead.future;
    return Future.value({'second_floor_rooms_json': '["WC","Salle de bain"]'});
  }

  @override
  Future<bool> refreshDiagnosticSanitaireFromRemote(String dossierId) async =>
      false;
}

final _dossier = Dossier(
  id: 'test-dossier',
  patient: Patient(
    id: 'test-patient',
    firstName: 'Test',
    lastName: 'Patient',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.IN_PROGRESS,
  ergoId: '',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.OTHER,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: const {},
  createdAt: '',
);

void main() {
  for (final bathroom in [true, false]) {
    testWidgets(
      '${bathroom ? 'Bathroom' : 'WC'} keeps the latest level after an older read finishes',
      (tester) async {
        final repository = _DelayedHousingRepository();

        Widget tab(int token) => MaterialApp(
          home: Scaffold(
            body: bathroom
                ? BathroomTab(
                    dossier: _dossier,
                    repository: repository,
                    housingRefreshToken: token,
                  )
                : WcTab(
                    dossier: _dossier,
                    repository: repository,
                    housingRefreshToken: token,
                  ),
          ),
        );

        await tester.pumpWidget(tab(0));
        await tester.pump();
        expect(repository.reads, 1);

        await tester.pumpWidget(tab(1));
        await tester.pumpAndSettle();
        expect(find.text('2e étage'), findsOneWidget);

        repository.firstRead.complete({'second_floor_rooms_json': '[]'});
        await tester.pumpAndSettle();
        expect(find.text('2e étage'), findsOneWidget);
      },
    );
  }
}
