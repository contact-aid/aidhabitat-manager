import 'dart:async';
import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/documents_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openPreview(
  WidgetTester tester, {
  required Future<void> Function(String) onSave,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showGeneralDialog<void>(
              context: context,
              barrierDismissible: false,
              pageBuilder: (_, animation, secondaryAnimation) =>
                  DocumentPreview(
                    doc: DocItem(
                      id: 'test-document',
                      type: 'doc',
                      name: 'document.docx',
                      title: 'Original',
                      date: '2026-09-09',
                    ),
                    onSave: onSave,
                    onDelete: () {},
                    onDownload: () {},
                  ),
            ),
            child: const Text('Open preview'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open preview'));
  await tester.pumpAndSettle();
}

Future<void> closeAndSave(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Fermer'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Enregistrer'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'failed save on close retains edits and allows a successful retry',
    (tester) async {
      var attempts = 0;
      await openPreview(
        tester,
        onSave: (title) async {
          expect(title, 'New title');
          if (++attempts == 1) throw const FileSystemException('disk full');
        },
      );
      await tester.enterText(find.byType(TextField), 'New title');
      await closeAndSave(tester);

      expect(find.byType(DocumentPreview), findsOneWidget);
      expect(find.text('New title'), findsOneWidget);
      expect(find.textContaining('Modifié'), findsOneWidget);
      expect(find.textContaining('stockage local'), findsOneWidget);

      await closeAndSave(tester);
      expect(attempts, 2);
      expect(find.byType(DocumentPreview), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('toolbar save keeps preview open and clears pending changes', (
    tester,
  ) async {
    final saved = <String>[];
    await openPreview(tester, onSave: (title) async => saved.add(title));
    await tester.enterText(find.byType(TextField), 'Renamed');
    await tester.pump();
    await tester.tap(find.byTooltip('Enregistrer'));
    await tester.pumpAndSettle();

    expect(saved, ['Renamed']);
    expect(find.byType(DocumentPreview), findsOneWidget);
    expect(find.textContaining('Modifié'), findsNothing);
    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    expect(find.byType(DocumentPreview), findsNothing);
    expect(find.text('Modifications non enregistrées'), findsNothing);
  });

  testWidgets('back cancels the confirmation and discard does not save', (
    tester,
  ) async {
    var saves = 0;
    await openPreview(tester, onSave: (_) async => saves++);
    await tester.enterText(find.byType(TextField), 'Unsaved');
    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DocumentPreview), findsOneWidget);
    expect(find.text('Unsaved'), findsOneWidget);

    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitter sans enregistrer'));
    await tester.pumpAndSettle();
    expect(saves, 0);
    expect(find.byType(DocumentPreview), findsNothing);
  });

  testWidgets(
    'in-flight save blocks editing, duplicate saves and back navigation',
    (tester) async {
      final completion = Completer<void>();
      var saves = 0;
      await openPreview(
        tester,
        onSave: (_) {
          saves++;
          return completion.future;
        },
      );
      await tester.enterText(find.byType(TextField), 'Pending');
      await tester.pump();
      await tester.tap(find.byTooltip('Enregistrer'));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
      for (final tooltip in [
        'Fermer',
        'Supprimer',
        'Télécharger',
        'Pivoter le document de 90°',
      ]) {
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) => widget is IconButton && widget.tooltip == tooltip,
                ),
              )
              .onPressed,
          isNull,
        );
      }
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.tap(find.byTooltip('Enregistrer'));
      await tester.pump();
      expect(saves, 1);
      expect(find.byType(DocumentPreview), findsOneWidget);
      expect(find.text('Modifications non enregistrées'), findsNothing);

      completion.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(find.textContaining('Modifié'), findsNothing);
      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      expect(find.byType(DocumentPreview), findsNothing);
    },
  );

  testWidgets(
    'rotation failure after rename does not close or repeat the rename',
    (tester) async {
      var saves = 0;
      await openPreview(tester, onSave: (_) async => saves++);
      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.tap(find.byTooltip('Pivoter le document de 90°'));
      await tester.pump();
      // This document has no source bytes, so rotation persistence must fail.
      await closeAndSave(tester);
      expect(saves, 1);
      expect(find.byType(DocumentPreview), findsOneWidget);
      expect(find.textContaining('Modifié'), findsOneWidget);
      await closeAndSave(tester);
      expect(saves, 1);
      expect(find.byType(DocumentPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
