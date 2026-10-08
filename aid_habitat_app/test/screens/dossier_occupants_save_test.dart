import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/dossier_screen.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
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

  for (final fullNames in [false, true]) {
    testWidgets(
      'split household (full names: $fullNames) displays and saves distinct identities',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _Repository();
        await tester.pumpWidget(
          MaterialApp(
            home: DossierScreen(
              dossier: dossier(fullNames: fullNames),
              repository: repository,
              onBack: () {},
            ),
          ),
        );
        await tester.pump();
        final first = fullNames ? 'Daniel' : 'René';
        final second = fullNames ? 'Heike' : 'Madeleine';
        final surname = fullNames ? 'LECUYER' : 'Exemple';
        expect(find.text('${surname.toUpperCase()} $first'), findsOneWidget);
        expect(find.text('${surname.toUpperCase()} $second'), findsOneWidget);
        expect(
          find.text(
            fullNames ? 'Daniel et Heike Lecuyer' : 'René et Madeleine Exemple',
          ),
          findsOneWidget,
        );
        expect(repository.writes, isEmpty);
        await tester.tap(find.byTooltip('Modifier'));
        await tester.pump();
        await tester.tap(find.byTooltip('Valider'));
        await tester.pump(kSaveDebounceText);
        expect(repository.writes, isEmpty);
        await tester.tap(find.byTooltip('Modifier'));
        await tester.pump();
        final dropdown = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(const ValueKey('occupant-0-gender-')),
        );
        dropdown.onChanged!('Homme');
        await tester.pump(kSaveDebounceText);
        await tester.pump();
        expect(repository.writes.length, 1);
        final fields = repository.writes.single;
        expect(fields['first_name'], first);
        expect(fields['second_first_name'], second);
        expect(fields['last_name'], surname);
        expect(fields['second_last_name'], surname);
        expect(fields['number_people'], 2);
        final occupants = jsonDecode(fields['occupants_json'] as String);
        expect(occupants[0]['gender'], 'Homme');
        expect(occupants[0]['apaGir'], '3');
        expect(occupants[1]['homeHelpTxt'], 'Aide conservée');
        expect(
          repository.baselines.single!['occupants_json'],
          'original-observed-json',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'removing an occupant requires confirmation and saves shifted identity',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _Repository();
      await tester.pumpWidget(
        MaterialApp(
          home: DossierScreen(
            dossier: dossier(),
            repository: repository,
            onBack: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Modifier'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('occupant-0-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Retirer cet occupant ?'), findsOneWidget);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(repository.writes, isEmpty);
      expect(find.byKey(const ValueKey('occupant-row-1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('occupant-0-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retirer').last);
      await tester.pump(kSaveDebounceText);
      await tester.pump();
      expect(repository.writes, hasLength(1));
      final fields = repository.writes.single;
      expect(fields['number_people'], 1);
      expect(fields['first_name'], 'Madeleine');
      expect(fields['second_first_name'], '');
      final occupants = jsonDecode(fields['occupants_json'] as String) as List;
      expect(occupants, hasLength(1));
      expect(occupants.single['homeHelpTxt'], 'Aide conservée');
      expect(find.byKey(const ValueKey('occupant-0-remove')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('adding needs confirmation and preserves every existing value', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    await tester.pumpWidget(
      MaterialApp(
        home: DossierScreen(
          dossier: dossier(),
          repository: repository,
          onBack: () {},
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Modifier'));
    await tester.pump();
    await tester.tap(find.text('Ajouter un occupant'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(repository.writes, isEmpty);
    expect(find.byKey(const ValueKey('occupant-row-2')), findsNothing);
    await tester.tap(find.text('Ajouter un occupant'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ajouter').last);
    await tester.pump(kSaveDebounceText);
    await tester.pump();
    final occupants =
        jsonDecode(repository.writes.single['occupants_json'] as String)
            as List;
    expect(occupants, hasLength(3));
    expect(occupants[0]['apaGir'], '3');
    expect(occupants[1]['homeHelpTxt'], 'Aide conservée');
    expect(repository.writes.single['number_people'], 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
