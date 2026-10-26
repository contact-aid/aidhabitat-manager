import 'dart:convert';
import 'dart:math' as math;
import 'package:aid_habitat_app/components/plan_canvas.dart';
import 'package:aid_habitat_app/components/plan_viewport.dart';
import 'package:aid_habitat_app/components/web_plan_image_viewport.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Plans extends Fake implements DataService {
  int writes = 0;
  @override
  Future<String?> fetchNoteDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
    String? dossierId,
  }) async => jsonEncode({
    'format': 'plan_canvas_v1',
    'strokes': [
      {
        'tool': 'rect',
        'size': 2,
        'color': 0xFF000000,
        'points': pageNumber == 0
            ? [
                [300, 400],
                [2700, 1900],
              ]
            : [
                [20, 20],
                [300, 220],
              ],
      },
      if (pageNumber == 0)
        {
          'tool': 'bath',
          'size': 2,
          'color': 0xFF000000,
          'rotation': math.pi / 4,
          'points': [
            [2800, 2000],
            [3200, 2200],
          ],
        },
    ],
  });
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #saveNoteDrawingJson) {
      writes++;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  for (final viewport in [
    const Size(1200, 800),
    const Size(500, 900),
    const Size(900, 300),
  ]) {
    test('fit contains distant drawing at $viewport', () {
      const bounds = Rect.fromLTRB(200, 300, 3800, 2500);
      final matrix = fitPlanViewport(
        viewport: viewport,
        canvas: const Size(4000, 2700),
        contentBounds: bounds,
      );
      expect(matrix.getMaxScaleOnAxis(), closeTo(matrix.entry(0, 0), .000001));
      final visible = MatrixUtils.transformRect(matrix, bounds);
      expect(visible.left, greaterThanOrEqualTo(0));
      expect(visible.top, greaterThanOrEqualTo(0));
      expect(visible.right, lessThanOrEqualTo(viewport.width));
      expect(visible.bottom, lessThanOrEqualTo(viewport.height));
      expect(visible.center.dx, closeTo(viewport.width / 2, .001));
      expect(visible.center.dy, closeTo(viewport.height / 2, .001));
    });
  }
  test('empty and point plans have finite transforms', () {
    for (final bounds in <Rect?>[null, const Rect.fromLTRB(20, 20, 20, 20)]) {
      final matrix = fitPlanViewport(
        viewport: const Size(800, 600),
        canvas: const Size(1600, 1200),
        contentBounds: bounds,
      );
      expect(matrix.storage.every((value) => value.isFinite), isTrue);
      expect(matrix.getMaxScaleOnAxis(), lessThanOrEqualTo(4));
    }
  });
  testWidgets(
    'web fits on load, button, resize and page change without saving',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _Plans();
      Widget page(int number) => MaterialApp(
        home: Scaffold(
          body: PlanCanvas(
            patientId: 'synthetic',
            dataService: service,
            pageNumber: number,
          ),
        ),
      );
      await tester.pumpWidget(page(0));
      await tester.pumpAndSettle();
      if (!kIsWeb) {
        expect(find.byTooltip('Recentrer le plan'), findsNothing);
        expect(
          tester
              .widget<InteractiveViewer>(find.byType(InteractiveViewer))
              .boundaryMargin,
          EdgeInsets.zero,
        );
        return;
      }
      void expectFit(Rect bounds) {
        final viewer = tester.widget<InteractiveViewer>(
          find.byType(InteractiveViewer),
        );
        final size = tester.getSize(find.byType(InteractiveViewer));
        final visible = MatrixUtils.transformRect(
          viewer.transformationController!.value,
          bounds,
        );
        expect(visible.left, greaterThanOrEqualTo(0));
        expect(visible.top, greaterThanOrEqualTo(0));
        expect(visible.right, lessThanOrEqualTo(size.width));
        expect(visible.bottom, lessThanOrEqualTo(size.height));
      }

      final radius = 600 / math.sqrt(2);
      final bounds = Rect.fromLTRB(300, 400, 2800 + radius, 2000 + radius);
      expectFit(bounds);
      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      controller.value = Matrix4.identity()..setTranslationRaw(-5000, -4000, 0);
      await tester.pump();
      await tester.tap(find.byTooltip('Recentrer le plan'));
      await tester.pumpAndSettle();
      expectFit(bounds);
      await tester.binding.setSurfaceSize(const Size(600, 420));
      await tester.pumpAndSettle();
      expectFit(bounds);
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      expectFit(const Rect.fromLTRB(20, 20, 300, 220));
      await tester.pump(const Duration(seconds: 1));
      expect(service.writes, 0);
    },
  );
  testWidgets('historical image reset and resize recover the fitted preview', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 650));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WebPlanImageViewport(
            child: SizedBox(
              width: 300,
              height: 200,
              child: ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer))
        .transformationController!;
    controller.value = Matrix4.identity()..setTranslationRaw(-500, -400, 0);
    await tester.pump();
    await tester.tap(find.byTooltip('Recentrer le plan'));
    await tester.pumpAndSettle();
    expect(controller.value, Matrix4.identity());
    controller.value = Matrix4.identity()..setTranslationRaw(-400, -300, 0);
    await tester.binding.setSurfaceSize(const Size(600, 400));
    await tester.pumpAndSettle();
    expect(controller.value, Matrix4.identity());
  });
}
