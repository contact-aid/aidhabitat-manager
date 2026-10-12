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
  testWidgets('keeps the current canvas mounted throughout a slow page turn', (
    tester,
  ) async {
    final key = GlobalKey<DocumentPageSlideState>();
    final ready = Completer<void>();
    var page = 1;
    var mounts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => DocumentPageSlide(
            key: key,
            page: page,
            current: _CanvasProbe(onMount: () => mounts++),
            next: const ColoredBox(
              key: ValueKey('incoming'),
              color: Colors.white,
            ),
            onPageChange: (direction) async {
              await ready.future;
              setState(() => page += direction);
            },
          ),
        ),
      ),
    );
    expect(mounts, 1);
    unawaited(key.currentState!.turnPage(1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 140));
    expect(mounts, 1, reason: 'Starting the slide must preserve the canvas');
    await tester.pump(const Duration(milliseconds: 400));
    expect(page, 1);
    expect(mounts, 1);
    // The incoming preview stays in the viewport while preparation finishes.
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('incoming'))).dx,
      closeTo(0, 0.01),
    );
    ready.complete();
    await tester.pumpAndSettle();
    expect(page, 2);
    expect(mounts, 1, reason: 'Completing the slide must preserve the canvas');
    expect(tester.takeException(), isNull);
  });
}

class _CanvasProbe extends StatefulWidget {
  const _CanvasProbe({required this.onMount});

  final VoidCallback onMount;

  @override
  State<_CanvasProbe> createState() => _CanvasProbeState();
}

class _CanvasProbeState extends State<_CanvasProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
