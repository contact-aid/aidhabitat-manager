import 'dart:async';

import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/accessibility_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository extends Fake implements DossierRepository {
  final writes = <Map<String, dynamic>>[];
  int pruneCalls = 0;
  Completer<void>? firstWriteGate;

  @override
  Future<Map<String, dynamic>?> fetchHousingRaw(String dossierId) async => {
    'typology': 'Maison',
    'surface': 30.0,
  };

  @override
  Future<void> updateHousing(
    String dossierId,
    Map<String, dynamic> changes, {
    Map<String, dynamic>? observedFields,
  }) async {
    writes.add(Map.of(changes));
    if (writes.length == 1) await firstWriteGate?.future;
  }

  @override
  Future<void> pruneDiagnosticSanitaireForRooms(
    String dossierId, {
    required Set<String> bathroomLevelFields,
    required Set<String> wcLevelFields,
  }) async {
    pruneCalls++;
  }
}

Dossier _dossier() => Dossier(
  id: 'fictive-dossier',
  patient: Patient(
    id: 'fictive-patient',
    firstName: 'Anne-Gaëlle',
    lastName: 'FICTIVE',
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
  ergoId: 'fictive-ergo',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: const {},
  createdAt: '2026-09-28',
);

void main() {
  Widget screen(_Repository repository) => MaterialApp(
    home: Scaffold(
      body: AccessibilityTab(dossier: _dossier(), repository: repository),
    ),
  );

  FormNumberField surfaceField(WidgetTester tester) =>
      tester.widget<FormNumberField>(
        find.byWidgetPredicate(
          (widget) =>
              widget is FormNumberField && widget.label == 'Surface habitable',
        ),
      );

  testWidgets('opening cached housing never prunes sanitary details', (
    tester,
  ) async {
    final repository = _Repository();
    await tester.pumpWidget(screen(repository));
    await tester.pumpAndSettle();
    expect(repository.pruneCalls, 0);
    expect(repository.writes, isEmpty);
  });

  testWidgets('last offline edit survives leaving before debounce fires', (
    tester,
  ) async {
    final repository = _Repository();
    await tester.pumpWidget(screen(repository));
    await tester.pumpAndSettle();

    surfaceField(tester).onChanged!(42);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(repository.writes, hasLength(1));
    expect(repository.writes.single['surface'], 42);
    expect(repository.pruneCalls, 0);
  });

  testWidgets('newest offline edit drains after an in-flight save and exit', (
    tester,
  ) async {
    final repository = _Repository()..firstWriteGate = Completer<void>();
    await tester.pumpWidget(screen(repository));
    await tester.pumpAndSettle();

    surfaceField(tester).onChanged!(41);
    await tester.pump(kSaveDebouncePills);
    expect(repository.writes, hasLength(1));

    surfaceField(tester).onChanged!(42);
    await tester.pumpWidget(const SizedBox.shrink());
    repository.firstWriteGate!.complete();
    await tester.pump();
    await tester.pump();

    expect(repository.writes, hasLength(2));
    expect(repository.writes.last['surface'], 42);
  });
}
