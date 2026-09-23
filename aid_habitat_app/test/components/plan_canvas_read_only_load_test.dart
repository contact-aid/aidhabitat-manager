import 'dart:convert';

import 'package:aid_habitat_app/components/plan_canvas.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _fictitiousDrawing =
    '{"format":"plan_canvas_v1","strokes":['
    '{"tool":"pen","color":4279900698,"size":2,'
    '"points":[[10,10],[30,30]]}]}';
const _legacyEraserDrawing =
    '{"format":"plan_canvas_v1","strokes":['
    '{"tool":"pen","color":4279900698,"size":2,'
    '"points":[[10,10],[30,30]]},'
    '{"tool":"eraser","color":4279900698,"size":8,'
    '"points":[[20,20],[21,21]]}]}';

class _RecordingDataService implements DataService {
  _RecordingDataService({this.drawing = _fictitiousDrawing});

  final String drawing;
  int saves = 0;

  @override
  Future<String?> fetchNoteDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
    String? dossierId,
  }) async => drawing;

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
    expect(patientId, 'fictitious-patient');
    expect(tabKey, 'Plans');
    expect(pageNumber, 1);
    final decoded = jsonDecode(drawingJson) as Map<String, dynamic>;
    expect(decoded['format'], 'plan_canvas_v1');
    expect((decoded['strokes'] as List).length, 1);
    expect(mutationOrigin, SyncMutationOrigin.userEdit);
    saves++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final justCreated in [false, true]) {
    testWidgets(
      justCreated
          ? 'a newly created scenario generates its preview once'
          : 'opening an existing after-work plan remains read-only',
      (tester) async {
        final dataService = _RecordingDataService();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: PlanCanvas(
                  patientId: 'fictitious-patient',
                  tabKey: 'Plans',
                  pageNumber: 1,
                  refreshPreviewOnLoad: justCreated,
                  dataService: dataService,
                  previewDataUrlBuilder: () async => null,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(dataService.saves, justCreated ? 1 : 0);
      },
    );
  }

  testWidgets('opening a legacy eraser plan remains read-only', (tester) async {
    final dataService = _RecordingDataService(drawing: _legacyEraserDrawing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: PlanCanvas(
              patientId: 'fictitious-patient',
              tabKey: 'Plans',
              pageNumber: 1,
              dataService: dataService,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(dataService.saves, 0);
  });
}
