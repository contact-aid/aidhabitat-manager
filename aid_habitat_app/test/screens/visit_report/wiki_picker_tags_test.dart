import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/recommendations_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  WikiItem item(String id, String title, List<String> tags) => WikiItem(
    id: id,
    title: title,
    description: '',
    imageUrl: '',
    tags: tags,
    category: '',
    createdAt: '',
    updatedAt: '',
  );
  final items = [
    item('angle', 'Barre appui angle', ['WC', "Barres d'appui"]),
    item('straight', 'Barre droite', ["Barres d'appui"]),
    item('shower', 'Douche', ['Salle de bain']),
  ];
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1024, 768),
    double keyboard = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WikiPickerDialog(items: items)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder chip(String label) => find.widgetWithText(ChoiceChip, label);

  testWidgets('tags match library items, sorted and deduplicated', (
    tester,
  ) async {
    await open(tester);
    expect(
      tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .map((w) => (w.label as Text).data),
      ['Tous', "Barres d'appui", 'Salle de bain', 'WC'],
    );
    expect(
      tester.getRect(chip('Tous')).top,
      greaterThan(tester.getRect(find.byType(TextField)).bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tag and keyword search combine; tags remain available with no results',
    (tester) async {
      await open(tester);
      await tester.tap(chip('WC'));
      await tester.pumpAndSettle();
      expect(find.text('Barre appui angle'), findsOneWidget);
      expect(find.text('Barre droite'), findsNothing);
      await tester.enterText(find.byType(TextField), 'barre angle');
      await tester.pumpAndSettle();
      expect(find.text('Barre appui angle'), findsOneWidget);
      await tester.tap(chip('Salle de bain'));
      await tester.pumpAndSettle();
      expect(find.text('Aucun résultat.'), findsOneWidget);
      expect(chip('WC'), findsOneWidget);
      await tester.tap(chip('Tous'));
      await tester.pumpAndSettle();
      expect(find.text('Barre appui angle'), findsOneWidget);
    },
  );

  testWidgets('clicking selected tag removes the filter', (tester) async {
    await open(tester);
    await tester.tap(chip('WC'));
    await tester.pumpAndSettle();
    await tester.tap(chip('WC'));
    await tester.pumpAndSettle();
    expect(find.text('Barre droite'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(chip('Tous')).selected, isTrue);
  });

  for (final size in [const Size(1024, 768), const Size(768, 1024)]) {
    testWidgets('picker contains filters and results with keyboard at $size', (
      tester,
    ) async {
      await open(tester, size: size, keyboard: 300);
      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(Dialog));
      final chips = tester.getRect(chip('Tous'));
      expect(chips.bottom, lessThan(dialog.bottom));
      await tester.tap(chip('WC'));
      await tester.pumpAndSettle();
      expect(find.text('Barre appui angle'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
