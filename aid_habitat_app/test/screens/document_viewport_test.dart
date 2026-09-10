import 'dart:convert';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/screens/documents_screen.dart';

void main() {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
  );
  testWidgets('web clicks step 10 percent and mouse pan never edits content', (
    tester,
  ) async {
    var edits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: documentViewportForTesting(bytes, () => edits++, web: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    TransformationController controller() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    await tester.tap(find.byTooltip('Agrandir de 10 %'));
    await tester.pumpAndSettle();
    expect(controller().value.getMaxScaleOnAxis(), closeTo(1.1, 0.001));
    await tester.tap(find.byTooltip('Agrandir de 10 %'));
    await tester.pumpAndSettle();
    expect(controller().value.getMaxScaleOnAxis(), closeTo(1.2, 0.001));
    final before = controller().value.clone();
    final gesture = await tester.startGesture(
      const Offset(350, 200),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(50, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller().value.entry(0, 3), isNot(before.entry(0, 3)));
    expect(controller().value.getMaxScaleOnAxis(), closeTo(1.2, 0.001));
    await tester.tap(find.byTooltip('Réduire de 10 %'));
    await tester.pumpAndSettle();
    expect(controller().value.getMaxScaleOnAxis(), closeTo(1.1, 0.001));
    expect(edits, 0);
    await tester.pumpWidget(const SizedBox());
    expect(edits, 0);
  });
  testWidgets('native gestures and toolbar remain unchanged', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: documentViewportForTesting(bytes, () {}, web: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Agrandir de 10 %'), findsNothing);
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .panEnabled,
      isFalse,
    );
  });
}
