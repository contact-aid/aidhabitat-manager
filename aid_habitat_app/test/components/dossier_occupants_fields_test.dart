import 'package:aid_habitat_app/components/dossier_occupants_fields.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [320.0, 640.0]) {
    testWidgets('identity rows can be edited and appended at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final occupants = <Occupant>[
        const Occupant(
          firstName: 'René',
          lastName: 'Exemple',
          apa: true,
          apaGir: '3',
        ),
        const Occupant(
          firstName: 'Madeleine',
          lastName: 'Exemple',
          gender: 'Femme',
        ),
      ];
      var changes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => DossierOccupantsFields(
                  occupants: occupants,
                  locked: false,
                  onChanged: (index, occupant) {
                    setState(() => occupants[index] = occupant);
                    changes++;
                  },
                  onAdd: () => setState(() => occupants.add(const Occupant())),
                  onRemove: (index) =>
                      setState(() => occupants.removeAt(index)),
                ),
              ),
            ),
          ),
        ),
      );
      expect(changes, 0);
      final nameInput = find.descendant(
        of: find.byKey(const ValueKey('occupant-0-firstName')),
        matching: find.byType(InputDecorator),
      );
      final genderInput = find.descendant(
        of: find.byKey(const ValueKey('occupant-0-gender-')),
        matching: find.byType(InputDecorator),
      );
      expect(
        tester.getSize(genderInput).height,
        tester.getSize(nameInput).height,
      );

      void expectMatchingVisibleBorders() {
        final nameEditor = find.descendant(
          of: find.byKey(const ValueKey('occupant-0-firstName')),
          matching: find.byType(EditableText),
        );
        final dropdown = find.descendant(
          of: find.byKey(const ValueKey('occupant-row-0')),
          matching: find.byType(DropdownButton<String>),
        );
        final nameBorder = InputDecorator.containerOf(
          tester.element(nameEditor),
        )!;
        final genderBorder = InputDecorator.containerOf(
          tester.element(
            find.descendant(of: dropdown, matching: find.byType(Icon)).first,
          ),
        )!;
        expect(genderBorder.size.height, nameBorder.size.height);
        if (width >= 520) {
          expect(
            genderBorder.localToGlobal(Offset.zero).dy,
            nameBorder.localToGlobal(Offset.zero).dy,
          );
        }
      }

      expectMatchingVisibleBorders();

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('occupant-0-firstName')),
          matching: find.byType(TextField),
        ),
        'Renée',
      );
      await tester.pump();
      expect(find.text('Non renseigné'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('occupant-0-gender-')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Madame').last);
      await tester.pumpAndSettle();
      expect(occupants.first.firstName, 'Renée');
      expect(occupants.first.gender, 'Femme');
      expectMatchingVisibleBorders();
      expect(occupants.first.apaGir, '3');
      await tester.tap(find.byKey(const ValueKey('occupant-0-gender-Femme')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Non précisé').last);
      await tester.pumpAndSettle();
      expect(occupants.first.gender, '');
      expect(find.text('Non précisé'), findsNothing);

      final maiden = find.descendant(
        of: find.byKey(const ValueKey('occupant-0-maidenName')),
        matching: find.byType(TextField),
      );
      await tester.enterText(maiden, 'Naissance');
      await tester.pump();
      expect(occupants.first.maidenName, 'Naissance');
      await tester.enterText(maiden, '');
      await tester.pump();
      expect(occupants.first.maidenName, '');
      expect(occupants.first.apaGir, '3');
      await tester.tap(find.text('Ajouter un occupant'));
      await tester.pumpAndSettle();
      expect(occupants.length, 3);
      expect(find.byKey(const ValueKey('occupant-row-2')), findsOneWidget);
      expect(occupants[1].firstName, 'Madeleine');
      await tester.tap(find.byKey(const ValueKey('occupant-2-remove')));
      await tester.pumpAndSettle();
      expect(occupants.length, 2);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'locked card shows civilities and full names without field labels',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DossierOccupantsFields(
              occupants: const [
                Occupant(
                  firstName: 'Madeleine',
                  lastName: 'Letord',
                  gender: 'Femme',
                ),
                Occupant(
                  firstName: 'René',
                  lastName: 'Letort',
                  gender: 'Homme',
                ),
                Occupant(firstName: 'Alex', lastName: 'Exemple'),
              ],
              locked: true,
              onChanged: (_, _) => fail('unexpected write'),
              onAdd: () => fail('unexpected add'),
            ),
          ),
        ),
      );
      expect(find.text('Mme. LETORD Madeleine'), findsOneWidget);
      expect(find.text('M. LETORT René'), findsOneWidget);
      expect(find.text('EXEMPLE Alex'), findsOneWidget);
      for (final label in ['Nom', 'Prénom', 'Genre', 'Occupant 1']) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Ajouter un occupant'), findsNothing);
    },
  );
}
