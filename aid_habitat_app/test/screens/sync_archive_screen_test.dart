import 'package:aid_habitat_app/models/sync_archive_entry.dart';
import 'package:aid_habitat_app/screens/sync_archive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SyncArchiveEntry entry({
  String id = 'e1',
  Object? previous = '0100000000',
  Object? next = '0611111111',
  String field = 'telephone',
  DateTime? restoredAt,
}) => SyncArchiveEntry.fromJson({
  'id': id,
  'archivedAt': '2026-11-26T09:15:00.000Z',
  'source': 'guarded',
  'tableLabel': 'Bénéficiaire',
  'field': field,
  'previous': previous,
  'next': next,
  'beneficiaryName': 'Synthétique PATIENT',
  'actor': 'ergo-test',
  'restoredAt': restoredAt?.toIso8601String(),
});

Future<void> pump(
  WidgetTester tester, {
  required Future<List<SyncArchiveEntry>> Function() load,
  Future<void> Function(String)? restore,
}) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: SyncArchiveScreen(load: load, restore: restore ?? (_) async {}),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows who changed what, with both values', (tester) async {
    await pump(tester, load: () async => [entry()]);
    expect(
      find.text('Synthétique PATIENT · Bénéficiaire · telephone'),
      findsOneWidget,
    );
    expect(find.text('0100000000'), findsOneWidget);
    expect(find.text('0611111111'), findsOneWidget);
    expect(find.textContaining('par ergo-test'), findsOneWidget);
    expect(find.text('Restaurer cette valeur'), findsOneWidget);
  });

  testWidgets('restores only after confirmation, then reloads', (tester) async {
    final restored = <String>[];
    var loads = 0;
    await pump(
      tester,
      load: () async {
        loads++;
        return [
          entry(restoredAt: restored.isEmpty ? null : DateTime(2026, 11, 26, 11)),
        ];
      },
      restore: (id) async => restored.add(id),
    );

    await tester.tap(find.text('Restaurer cette valeur'));
    await tester.pumpAndSettle();
    expect(find.text('Restaurer cette valeur ?'), findsOneWidget);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(restored, isEmpty, reason: 'cancel restores nothing');

    await tester.tap(find.text('Restaurer cette valeur'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restaurer'));
    await tester.pumpAndSettle();
    expect(restored, ['e1']);
    expect(loads, 2);
    expect(find.textContaining('Restaurée le'), findsOneWidget);
    expect(find.text('Restaurer cette valeur'), findsNothing);
  });

  testWidgets('explains when the archive is not in service yet', (tester) async {
    await pump(
      tester,
      load: () async =>
          throw Exception("L'archive n'est pas encore en service sur le serveur."),
    );
    expect(
      find.text("L'archive n'est pas encore en service sur le serveur."),
      findsOneWidget,
    );
  });

  testWidgets('empty archive says nothing was overwritten', (tester) async {
    await pump(tester, load: () async => const []);
    expect(find.textContaining('Rien n\'a été écrasé'), findsOneWidget);
  });

  test('archived values are rendered readably', () {
    expect(describeArchivedValue(null), '(vide)');
    expect(describeArchivedValue('true'), 'Oui');
    expect(describeArchivedValue(['Salon', 'Cuisine']), 'Salon • Cuisine');
    expect(
      describeArchivedValue({'pathology': 'Arthrose', 'followUp': ''}),
      'pathology : Arthrose',
    );
  });
}
