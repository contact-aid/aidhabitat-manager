import 'package:aid_habitat_app/components/retained_space_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('switching retains edits and disables focus in hidden space', (
    tester,
  ) async {
    var documents = false;
    var dossierId = 'first-dossier';
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return RetainedSpaceSwitcher(
                key: ValueKey(dossierId),
                showSecond: documents,
                firstBuilder: (_) =>
                    const TextField(key: ValueKey('report-notes')),
                secondBuilder: (_) =>
                    const TextField(key: ValueKey('document-notes')),
              );
            },
          ),
        ),
      ),
    );
    const reportKey = ValueKey('report-notes');
    const documentKey = ValueKey('document-notes');
    expect(find.byKey(documentKey, skipOffstage: false), findsNothing);
    await tester.enterText(find.byKey(reportKey), 'Rédaction en cours');
    rebuild(() => documents = true);
    await tester.pumpAndSettle();
    expect(find.byKey(reportKey), findsNothing);
    final reportField = find.descendant(
      of: find.byKey(reportKey, skipOffstage: false),
      matching: find.byType(EditableText, skipOffstage: false),
    );
    expect(
      tester.widget<EditableText>(reportField).focusNode.canRequestFocus,
      isFalse,
    );
    await tester.enterText(find.byKey(documentKey), 'Légende du document');
    rebuild(() => documents = false);
    await tester.pumpAndSettle();
    expect(find.text('Rédaction en cours'), findsOneWidget);
    rebuild(() => documents = true);
    await tester.pumpAndSettle();
    expect(find.text('Légende du document'), findsOneWidget);
    rebuild(() {
      dossierId = 'second-dossier';
      documents = false;
    });
    await tester.pumpAndSettle();
    expect(find.text('Rédaction en cours', skipOffstage: false), findsNothing);
    expect(find.byKey(documentKey, skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can open Documents first without mounting the report', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RetainedSpaceSwitcher(
          showSecond: true,
          firstBuilder: (_) => const Text('Report'),
          secondBuilder: (_) => const Text('Documents'),
        ),
      ),
    );
    expect(find.text('Report', skipOffstage: false), findsNothing);
    expect(find.text('Documents'), findsOneWidget);
  });
}
