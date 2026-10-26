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
}
