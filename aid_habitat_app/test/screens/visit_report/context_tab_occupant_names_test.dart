import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/context_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

class _Repository extends Fake implements DossierRepository {
  int writes = 0;

  @override
  Future<Map<String, dynamic>?> fetchContexteDeVie(String dossierId) async => {
    'autonomy': const AutonomyData(
      occupants: [
        OccupantAutonomy(medical: MedicalContext(heightCm: '171')),
        OccupantAutonomy(medical: MedicalContext(heightCm: '162')),
      ],
    ).toJson(),
  };

  @override
  Future<void> upsertContexteDeVie(
    String dossierId,
    String patientId, {
    MedicalContext? medicalContext,
    AutonomyData? autonomy,
  }) async {
    writes++;
  }
}

Widget _screen(Dossier dossier, _Repository repository, int section) =>
    MaterialApp(
      home: Scaffold(
        body: ContextTab(
          dossier: dossier,
          repository: repository,
          initialSubSection: section,
        ),
      ),
    );

Dossier _dossier({
  List<Occupant> occupants = const [],
  String firstName = 'Alice et Paul',
  String secondFirstName = '',
  int? numberPeople = 2,
}) => Dossier(
  id: 'fictive-dossier',
  patient: Patient(
    id: 'fictive-patient',
    firstName: firstName,
    secondFirstName: secondFirstName,
    numberPeople: numberPeople,
    occupants: occupants,
    lastName: 'Exemple',
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
  createdAt: '2026-09-24',
);

void main() {
  for (final section in [0, 1]) {
    testWidgets(
      'section $section uses individual identities instead of grouped dossier title',
      (tester) async {
        final repository = _Repository();
        await tester.pumpWidget(
          _screen(
            _dossier(
              occupants: const [
                Occupant(firstName: 'Alice', lastName: 'Exemple'),
                Occupant(firstName: 'Paul', lastName: 'Exemple'),
              ],
            ),
            repository,
            section,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('EXEMPLE Alice'), findsOneWidget);
        expect(find.text('Alice et Paul EXEMPLE'), findsNothing);
        await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
        await tester.pumpAndSettle();
        expect(find.text('EXEMPLE Paul'), findsOneWidget);
        expect(find.text('Occupant 2'), findsNothing);
        expect(repository.writes, 0);
      },
    );
  }

  testWidgets('legacy grouped names use the same projection as Beneficiary', (
    tester,
  ) async {
    final repository = _Repository();
    await tester.pumpWidget(_screen(_dossier(), repository, 1));
    await tester.pumpAndSettle();
    expect(find.text('EXEMPLE Alice'), findsOneWidget);
    await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
    await tester.pumpAndSettle();
    expect(find.text('EXEMPLE Paul'), findsOneWidget);
    expect(repository.writes, 0);
  });

  testWidgets(
    'secondary legacy identity remains reachable without numberPeople',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        _screen(
          _dossier(
            firstName: 'Alice',
            secondFirstName: 'Paul',
            numberPeople: null,
          ),
          repository,
          1,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
      await tester.pumpAndSettle();
      expect(find.text('Paul'), findsOneWidget);
      expect(repository.writes, 0);
    },
  );

  testWidgets(
    'mounted context follows occupant-only identity changes and keeps medical values',
    (tester) async {
      final repository = _Repository();
      await tester.pumpWidget(
        _screen(
          _dossier(
            occupants: const [
              Occupant(firstName: 'Alice', lastName: 'Exemple'),
              Occupant(firstName: 'Paul', lastName: 'Exemple'),
            ],
          ),
          repository,
          0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('171'), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.chevronRight).first);
      await tester.pumpAndSettle();
      expect(find.text('162'), findsOneWidget);
      await tester.pumpWidget(
        _screen(
          _dossier(
            occupants: const [
              Occupant(firstName: 'Alice', lastName: 'Exemple'),
              Occupant(firstName: 'Pierre', lastName: 'Corrigé'),
            ],
          ),
          repository,
          0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CORRIGÉ Pierre'), findsOneWidget);
      expect(find.text('162'), findsOneWidget);
      expect(repository.writes, 0);
    },
  );
}
