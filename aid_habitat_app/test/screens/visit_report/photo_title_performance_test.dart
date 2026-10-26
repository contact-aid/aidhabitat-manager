import 'dart:async';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/photos_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final photo = DocItem(
    id: 'synthetic-photo-title',
    type: 'image',
    name: 'photo.png',
    title: 'Avant',
    date: '2026-10-26',
    dataUrl:
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );

  testWidgets('typing a photo title does not rebuild the image viewer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoFullscreenDialog(
            doc: photo,
            onMetadataChanged:
                ({required newTitle, required showLabelOnPdf}) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewer = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    await tester.enterText(find.byType(TextFormField), 'Salle de bain');
    await tester.pump();
    expect(
      identical(
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)),
        viewer,
      ),
      isTrue,
    );
    expect(find.text('Salle de bain'), findsOneWidget);
  });

  testWidgets(
    'saving persists the draft once and protects it until completion',
    (tester) async {
      final saved = Completer<void>();
      final titles = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoFullscreenDialog(
              doc: photo,
              onMetadataChanged:
                  ({required newTitle, required showLabelOnPdf}) async {
                    titles.add(newTitle);
                    await saved.future;
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Titre conservé');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(titles, ['Titre conservé']);
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isFalse,
      );
      saved.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
        isTrue,
      );
      expect(find.text('Titre conservé'), findsOneWidget);
    },
  );
  testWidgets(
    'first click after editing saves the title and PDF choice together',
    (tester) async {
      final pending = Completer<void>();
      final calls = <(String, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoFullscreenDialog(
              doc: photo,
              onMetadataChanged:
                  ({required newTitle, required showLabelOnPdf}) async {
                    calls.add((newTitle, showLabelOnPdf));
                    await pending.future;
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Nouveau titre');
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(calls, [('Nouveau titre', true)]);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      pending.complete();
      await tester.pumpAndSettle();
      expect(calls.length, 1);
    },
  );

  testWidgets('rapid toggles are serialized and the last choice wins', (
    tester,
  ) async {
    final pending = Completer<void>();
    final calls = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PhotoFullscreenDialog(
            doc: photo,
            onMetadataChanged:
                ({required newTitle, required showLabelOnPdf}) async {
                  calls.add(showLabelOnPdf);
                  if (calls.length == 1) await pending.future;
                },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(calls, [true]);
    pending.complete();
    await tester.pumpAndSettle();
    expect(calls, [true, false]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets(
    'failed save restores the confirmed PDF choice and permits retry',
    (tester) async {
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotoFullscreenDialog(
              doc: photo,
              onMetadataChanged:
                  ({required newTitle, required showLabelOnPdf}) async {
                    if (fail) throw StateError('synthetic failure');
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('Enregistrement impossible'), findsOneWidget);
      fail = false;
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    },
  );
  testWidgets(
    'one close click waits for a pending save then closes the dialog',
    (tester) async {
      final pending = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PhotoFullscreenDialog(
                    doc: photo,
                    onMetadataChanged:
                        ({required newTitle, required showLabelOnPdf}) =>
                            pending.future,
                  ),
                ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.byTooltip('Fermer'));
      await tester.pump();
      expect(find.byType(PhotoFullscreenDialog), findsOneWidget);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PhotoFullscreenDialog), findsNothing);
    },
  );
}
