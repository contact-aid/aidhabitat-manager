import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/context_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Repository extends Fake implements DossierRepository {
  late MedicalContext medical;
  late AutonomyData autonomy;
  final writes = <(MedicalContext?, AutonomyData?)>[];

  @override
  Future<Map<String, dynamic>?> fetchContexteDeVie(String dossierId) async => {
    'medicalContext': medical.toJson(),
    'autonomy': autonomy.toJson(),
  };

  @override
  Future<void> upsertContexteDeVie(
    String dossierId,
    String patientId, {
    MedicalContext? medicalContext,
    AutonomyData? autonomy,
  }) async {
    writes.add((medicalContext, autonomy));
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
  createdAt: '2026-09-24',
);

AutonomyData _autonomy({required bool secondChecked}) {
  final checklist = [
    for (var i = 0; i < kAutonomyItemNames.length; i++)
      AutonomyItem(
        name: kAutonomyItemNames[i],
        checked: i == 1 && secondChecked,
      ),
  ];
  final attention = [
    for (var i = 0; i < kAutonomyItemNames.length; i++)
      AutonomyItem(name: kAutonomyItemNames[i], checked: i == 0),
  ];
  return AutonomyData(
    done: false,
    checklist: checklist,
    occupants: [
      OccupantAutonomy(
        medical: const MedicalContext(heightCm: '170', weightKg: '76.0'),
        autonomy: checklist,
        attention: attention,
      ),
    ],
  );
}

void main() {
  testWidgets('height edit after server choice keeps refreshed autonomy', (
    tester,
  ) async {
    final repository = _Repository()
      ..medical = const MedicalContext(heightCm: '170', weightKg: '76.0')
      ..autonomy = _autonomy(secondChecked: false);
    final dossier = _dossier();

    Widget screen(int token) => MaterialApp(
      home: Scaffold(
        body: ContextTab(
          dossier: dossier,
          repository: repository,
          conflictRefreshToken: token,
        ),
      ),
    );

    await tester.pumpWidget(screen(0));
    await tester.pumpAndSettle();
    repository.autonomy = _autonomy(secondChecked: true);
    await tester.pumpWidget(screen(1));
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);

    final height = tester.widget<FormNumberField>(
      find.byWidgetPredicate(
        (widget) => widget is FormNumberField && widget.label == 'Taille',
      ),
    );
    height.onChanged!(172);
    await tester.pump(kSaveDebouncePills);
    await tester.pump();

    expect(repository.writes, hasLength(1));
    expect(repository.writes.single.$1!.heightCm, '172');
    final saved = repository.writes.single.$2!;
    expect(saved.checklist[1].checked, isTrue);
    expect(saved.occupants.single.attention.first.checked, isTrue);
  });
}
