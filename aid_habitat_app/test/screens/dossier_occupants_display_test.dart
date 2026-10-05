import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/dossier_screen.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Repository extends Fake implements DossierRepository {
  final writes = <Map<String, dynamic>>[];
  final baselines = <Map<String, dynamic>?>[];
  @override
  Future<void> updatePatient(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async {
    writes.add(Map.of(fields));
    baselines.add(observedFields);
  }
}

Dossier dossier({bool fullNames = false}) => Dossier(
  id: 'synthetic-dossier',
  patient: Patient(
    id: '',
    firstName: fullNames ? 'LECUYER Heike' : 'René et Madeleine',
    lastName: fullNames ? 'LECUYER Daniel' : 'Exemple',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    numberPeople: 2,
    occupants: const [
      Occupant(apa: true, apaGir: '3'),
      Occupant(homeHelpTxt: 'Aide conservée'),
    ],
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  patientEditBaseline: {'occupants_json': 'original-observed-json'},
  status: DossierStatus.TO_VISIT,
  ergoId: '',
  createdAt: '2026-09-01',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    GoogleFonts.config.allowRuntimeFetching = false;
  });
  testWidgets('opening and reopening split display never writes patient data', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    for (final fullNames in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(
          home: DossierScreen(
            key: ValueKey(fullNames),
            dossier: dossier(fullNames: fullNames),
            repository: repository,
            onBack: () {},
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Bénéficiaires'), findsOneWidget);
      expect(find.text('Occupants'), findsOneWidget);
      expect(
        find.text(
          fullNames
              ? 'LECUYER Daniel\nLECUYER Heike'
              : 'EXEMPLE René\nEXEMPLE Madeleine',
        ),
        findsOneWidget,
      );
      expect(repository.writes, isEmpty);
      expect(
        find.byKey(const ValueKey('occupant-identity-review')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(repository.writes, isEmpty);
    }
  });
}
