import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:aid_habitat_app/components/document_page_slide.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('page follows a touch and returns when dragged back', (
    tester,
  ) async {
    final key = GlobalKey<DocumentPageSlideState>();
    var page = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 400,
            height: 400,
            child: DocumentPageSlide(
              key: key,
              page: page,
              current: Text('Page $page'),
              next: const Text('Page 2'),
              onPageChange: (direction) async {
                setState(() => page += direction);
              },
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Page 1')),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(-160, 0));
    await tester.pump();
    expect(find.text('Page 2'), findsOneWidget);
    await gesture.moveBy(const Offset(160, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(page, 1);

    unawaited(key.currentState!.turnPage(1));
    await tester.pumpAndSettle();
    expect(page, 2);
  });
}
