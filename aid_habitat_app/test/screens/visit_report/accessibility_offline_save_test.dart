import 'dart:async';
import 'dart:convert';
import 'package:lucide_icons/lucide_icons.dart';

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
  final removedBathrooms = <String>{};
  Map<String, dynamic> housing = {'typology': 'Maison', 'surface': 30.0};
  @override
  Future<DiagnosticSanitaire?> fetchDiagnosticSanitaire(String id) async =>
      DiagnosticSanitaire(
        dossierId: id,
        sdbInstances: [
          BathroomInstance(
            id: 'first-bath',
            housingRoomId: 'room-a',
            levelField: 'rdc',
            levelLabel: 'RDC',
          ),
          BathroomInstance(
            id: 'second-bath',
            housingRoomId: 'room-b',
            levelField: 'rdc',
            levelLabel: 'RDC',
          ),
        ],
        wcInstances: [],
      );
  @override
  Future<void> removeDiagnosticRooms(
    String id, {
    required Set<String> bathroomIds,
    required Set<String> wcIds,
  }) async {
    removedBathrooms.addAll(bathroomIds);
  }

  Completer<void>? firstWriteGate;

  @override
  Future<Map<String, dynamic>?> fetchHousingRaw(String dossierId) async =>
      housing;

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

  testWidgets(
    'removing one bathroom keeps the other housing and diagnostic identity',
    (tester) async {
      final repository = _Repository();
      repository.housing.addAll({
        'rdc': 1,
        'levels': '["rdc"]',
        'rdc_rooms_json':
            '[{"id":"room-a","label":"Salle de bain"},{"id":"room-b","label":"Salle de bain"}]',
      });
      await tester.binding.setSurfaceSize(const Size(1100, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(screen(repository));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Niveaux'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('collapsed-rdc')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salle de bain').last);
      await tester.pumpAndSettle();
      final adjuster = find.byKey(
        const ValueKey<String>('adjuster-rdc-Salle de bain'),
      );
      await tester.tap(
        find.descendant(of: adjuster, matching: find.byIcon(LucideIcons.minus)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      final saved =
          jsonDecode(repository.writes.last['rdc_rooms_json']) as List;
      expect(saved, [
        {'id': 'room-a', 'label': 'Salle de bain'},
      ]);
      expect(repository.removedBathrooms, {'second-bath'});
      expect(repository.pruneCalls, 0);
    },
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
