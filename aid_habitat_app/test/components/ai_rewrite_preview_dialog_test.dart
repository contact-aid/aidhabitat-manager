import 'dart:async';
import 'package:aid_habitat_app/components/ai_rewrite_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> open(
    WidgetTester tester,
    Future<String> Function(BuildContext) generate, {
    VoidCallback? cancel,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<String>(
                context: context,
                builder: (_) => AiRewritePreviewDialog(
                  originalText: 'Note originale de test.',
                  generate: generate,
                  onCancel: cancel ?? () {},
                  phase: () => 'Reformulation en cours…',
                ),
              ),
              child: const Text('Ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Ouvrir'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets(
    'shows original immediately and enables editable proposal only after generation',
    (tester) async {
      final result = Completer<String>();
      await open(tester, (_) => result.future);
      expect(find.text('Note originale de test.'), findsOneWidget);
      expect(find.text('Proposition modifiable'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNull,
      );
      result.complete('Proposition de test.');
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Proposition ajustée.');
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Utiliser la proposition'));
      await tester.pumpAndSettle();
      expect(find.byType(AiRewritePreviewDialog), findsNothing);
    },
  );

  testWidgets('closing cancels pending work and safely ignores a late result', (
    tester,
  ) async {
    final result = Completer<String>();
    var cancelled = 0;
    await open(tester, (_) => result.future, cancel: () => cancelled++);
    await tester.tap(find.text('Conserver l’original'));
    await tester.pumpAndSettle();
    expect(cancelled, 1);
    result.complete('Résultat tardif.');
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Résultat tardif.'), findsNothing);
  });

  testWidgets(
    'error preserves original, disables acceptance and allows retry',
    (tester) async {
      var attempts = 0;
      await open(tester, (_) async {
        if (++attempts == 1) throw Exception('Erreur locale de test.');
        return 'Proposition après nouvel essai.';
      });
      expect(find.text('Erreur locale de test.'), findsOneWidget);
      expect(find.text('Note originale de test.'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Réessayer'));
      await tester.pump();
      expect(attempts, 2);
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Conserver l’original'));
      await tester.pumpAndSettle();
    },
  );
}
