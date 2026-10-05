import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:aid_habitat_app/components/plan_canvas.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';

class _MemoryPlanDataService implements DataService {
  String? drawing;
  int writes = 0;
  final savedPages = <int, String>{};
  final delayedLoads = <int, Completer<String?>>{};

  @override
  Future<String?> fetchNoteDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
    String? dossierId,
  }) async => delayedLoads[pageNumber]?.future ?? drawing;

  @override
  Future<void> saveNoteDrawingJson({
    required String patientId,
    required String tabKey,
    required String drawingJson,
    int pageNumber = 0,
    String? previewDataUrl,
    String? dossierId,
    String? scopeType,
    String? scopeId,
    required SyncMutationOrigin mutationOrigin,
  }) async {
    drawing = drawingJson;
    savedPages[pageNumber] = drawingJson;
    writes++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('palm contacts do not discard an active Pencil stroke', (
    tester,
  ) async {
    final service = _MemoryPlanDataService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanCanvas(
            patientId: 'fictional-patient',
            dataService: service,
            previewDataUrlBuilder: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final pen = await tester.startGesture(
      const Offset(400, 250),
      pointer: 1,
      kind: ui.PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(20, 20));
    await tester.pump();
    final palm1 = await tester.startGesture(const Offset(550, 350), pointer: 2);
    final palm2 = await tester.startGesture(const Offset(600, 350), pointer: 3);
    await tester.pump();
    await pen.moveBy(const Offset(30, 30));
    await pen.up();
    await palm1.up();
    await palm2.up();
    await tester.pump(const Duration(seconds: 1));
    final strokes = jsonDecode(service.drawing!)['strokes'] as List;
    expect(strokes, hasLength(1));
    expect(strokes.single['tool'], 'pen');
    expect((strokes.single['points'] as List).length, greaterThanOrEqualTo(3));
  });

  testWidgets(
    'editing a large existing plan preserves metadata and its full extent',
    (tester) async {
      final service = _MemoryPlanDataService()
        ..drawing =
            '{"format":"plan_canvas_v1","text":"Ancienne note conservée","custom":{"scale":20},"strokes":[{"tool":"pen","color":4279900698,"size":2,"points":[[2500,1800],[2600,1900]]}]}';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanCanvas(
              patientId: 'fictional-patient',
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final viewport = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final canvas = viewport.child! as SizedBox;
      expect(canvas.width, greaterThanOrEqualTo(2700));
      expect(canvas.height, greaterThanOrEqualTo(2000));
      expect(service.writes, 0);
      await tester.dragFrom(const Offset(400, 300), const Offset(70, 40));
      await tester.pump(const Duration(seconds: 1));
      final saved = jsonDecode(service.drawing!);
      expect(saved['text'], 'Ancienne note conservée');
      expect(saved['custom'], {'scale': 20});
      expect(saved['strokes'].first['points'], [
        [2500.0, 1800.0],
        [2600.0, 1900.0],
      ]);
    },
  );

  testWidgets('a late page load cannot replace the selected page', (
    tester,
  ) async {
    final service = _MemoryPlanDataService();
    service.delayedLoads[0] = Completer<String?>();
    service.delayedLoads[1] = Completer<String?>();
    final controller = PlanCanvasController();
    Widget screen(int page) => MaterialApp(
      home: Scaffold(
        body: PlanCanvas(
          patientId: 'fictional-patient',
          pageNumber: page,
          controller: controller,
          dataService: service,
          refreshPreviewOnLoad: true,
          previewDataUrlBuilder: () async => null,
        ),
      ),
    );
    await tester.pumpWidget(screen(0));
    await tester.pumpWidget(screen(1));
    service.delayedLoads[1]!.complete(
      '{"format":"plan_canvas_v1","strokes":[{"tool":"pen","color":4279900698,"size":2,"points":[[500,400],[520,420]]}]}',
    );
    await tester.pump();
    service.delayedLoads[0]!.complete(
      '{"format":"plan_canvas_v1","strokes":[{"tool":"rect","color":4279900698,"size":2,"points":[[10,10],[20,20]]}]}',
    );
    await tester.pump();
    await controller.flush();
    expect(service.savedPages.keys, [1]);
    expect(
      (jsonDecode(service.savedPages[1]!)['strokes'] as List).single['tool'],
      'pen',
    );
  });

  testWidgets('pending save retains the previous independent page kind', (
    tester,
  ) async {
    final service = _MemoryPlanDataService();
    Widget screen(int page) => MaterialApp(
      home: Scaffold(
        body: PlanCanvas(
          patientId: 'fictional-patient',
          pageNumber: page,
          independentPage: page == 0,
          dataService: service,
          previewDataUrlBuilder: () async => null,
        ),
      ),
    );
    await tester.pumpWidget(screen(0));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(400, 300), const Offset(80, 50));
    await tester.pumpWidget(screen(1));
    await tester.pumpAndSettle();
    expect(jsonDecode(service.savedPages[0]!)['pageKind'], 'blank');
    expect(service.savedPages.containsKey(1), false);
  });

  testWidgets(
    'rectangle needs a drag and stays fixed; equipment remains editable',
    (tester) async {
      final service = _MemoryPlanDataService();
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanCanvas(
              patientId: 'fictional-patient',
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tracer : Rectangle'));
      await tester.tapAt(const Offset(500, 300));
      await tester.pump(const Duration(seconds: 1));
      expect(service.writes, 0);

      await tester.dragFrom(const Offset(500, 300), const Offset(120, 80));
      await tester.pump(const Duration(seconds: 1));
      final afterRectangle =
          jsonDecode(service.drawing!) as Map<String, dynamic>;
      expect((afterRectangle['strokes'] as List).single['tool'], 'rect');
      await tester.tapAt(const Offset(550, 335));
      await tester.pump();
      expect(find.byTooltip('Supprimer'), findsNothing);

      await tester.tap(find.byTooltip('Tracer : WC'));
      await tester.dragFrom(const Offset(700, 350), const Offset(100, 80));
      await tester.pump(const Duration(seconds: 1));
      final afterEquipment =
          jsonDecode(service.drawing!) as Map<String, dynamic>;
      expect((afterEquipment['strokes'] as List).last['tool'], 'toilet');
      await tester.tapAt(const Offset(750, 390));
      await tester.pump();
      expect(find.byTooltip('Supprimer'), findsOneWidget);
      final qaDir = Platform.environment['APP_ERGO_UI_QA_DIR'];
      if (qaDir != null) {
        await tester.pump();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first,
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$qaDir/plans-fictionnels.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );

  testWidgets('hand pans and two fingers zoom without adding a stroke', (
    tester,
  ) async {
    final service = _MemoryPlanDataService();
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanCanvas(
            patientId: 'fictional-patient',
            dataService: service,
            previewDataUrlBuilder: () async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final viewport = tester.widget<InteractiveViewer>(
      find.byType(InteractiveViewer),
    );
    final transform = viewport.transformationController!;
    final canvas = viewport.child! as SizedBox;
    void expectGridCoversViewport() {
      final scale = transform.value.getMaxScaleOnAxis();
      final offset = transform.value.getTranslation();
      expect(offset.x, lessThanOrEqualTo(0.1));
      expect(offset.y, lessThanOrEqualTo(0.1));
      expect(offset.x + canvas.width! * scale, greaterThanOrEqualTo(1199.9));
      expect(offset.y + canvas.height! * scale, greaterThanOrEqualTo(799.9));
    }

    expect(viewport.boundaryMargin, EdgeInsets.zero);
    expectGridCoversViewport();
    final initialOffset = transform.value.getTranslation();
    expect(
      -initialOffset.x,
      closeTo(canvas.width! - 1200 + initialOffset.x, 0.1),
    );
    expect(
      -initialOffset.y,
      closeTo(canvas.height! - 800 + initialOffset.y, 0.1),
    );

    await tester.tap(find.byIcon(LucideIcons.hand));
    await tester.pump();
    expect(
      tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .panEnabled,
      isTrue,
    );
    final pan = await tester.startGesture(const Offset(800, 400));
    await pan.moveBy(const Offset(-90, -40));
    await tester.pump();
    await pan.moveBy(const Offset(-90, -40));
    await pan.up();
    await tester.pumpAndSettle();
    expect(transform.value.getTranslation().x, lessThan(-50));
    expectGridCoversViewport();
    expect(service.writes, 0);

    final farPan = await tester.startGesture(const Offset(800, 400));
    await farPan.moveBy(const Offset(-2000, -2000));
    await tester.pump();
    await farPan.up();
    await tester.pumpAndSettle();
    expectGridCoversViewport();

    final oppositePan = await tester.startGesture(const Offset(400, 300));
    await oppositePan.moveBy(const Offset(2000, 2000));
    await tester.pump();
    await oppositePan.up();
    await tester.pumpAndSettle();
    expectGridCoversViewport();

    await tester.tap(find.byTooltip('Crayon'));
    final first = await tester.startGesture(const Offset(500, 350), pointer: 1);
    final second = await tester.startGesture(
      const Offset(620, 350),
      pointer: 2,
    );
    await tester.pump();
    await first.moveTo(const Offset(450, 350));
    await second.moveTo(const Offset(670, 350));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    final zoomedInScale = transform.value.getMaxScaleOnAxis();
    expect(zoomedInScale, greaterThan(1));
    expectGridCoversViewport();

    final inwardFirst = await tester.startGesture(
      const Offset(450, 350),
      pointer: 3,
    );
    final inwardSecond = await tester.startGesture(
      const Offset(750, 350),
      pointer: 4,
    );
    await tester.pump();
    await inwardFirst.moveTo(const Offset(570, 350));
    await inwardSecond.moveTo(const Offset(630, 350));
    await tester.pump();
    await inwardFirst.up();
    await inwardSecond.up();
    await tester.pumpAndSettle();
    expect(transform.value.getMaxScaleOnAxis(), lessThan(zoomedInScale));
    expectGridCoversViewport();
    expect(service.writes, 0);
  });
}
