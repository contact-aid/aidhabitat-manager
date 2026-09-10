import 'dart:async';
import 'package:aid_habitat_app/screens/database_unavailable_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('retry is single-flight and remains available after a failure', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DatabaseUnavailableScreen(
          onRetry: () {
            calls++;
            return pending.future;
          },
        ),
      ),
    );
    await tester.tap(find.text('R\u00e9essayer'));
    await tester.tap(find.text('R\u00e9essayer'));
    await tester.pump();
    expect(calls, 1);
    pending.completeError(StateError('still unavailable'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Stockage local indisponible'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('recovery fits a narrow screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: DatabaseUnavailableScreen(onRetry: () async {}),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('R\u00e9essayer'), findsOneWidget);
  });
}
