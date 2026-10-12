import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/models/visit_report_categories.dart';
import 'package:aid_habitat_app/screens/visit_report/plans_tab.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PlansDataService implements DataService {
  final drawings = <int, String>{};
  final phases = <int, PlanPhase?>{};
  String? lastDuplicatePreview;
  int? lastDuplicateSource;
  int writes = 0;

  @override
  Future<List<LocalNotePageSnapshot>> fetchLocalNotePages({
    required String patientId,
    required String dossierId,
    String tabKey = 'Plans',
  }) async => [
    for (final entry in drawings.entries)
      LocalNotePageSnapshot(
        pageNumber: entry.key,
        drawingJson: entry.value,
        textContent: '',
        planPhase: phases[entry.key],
      ),
  ];

  @override
  Future<int> duplicateLocalNotePage({
    required String patientId,
    required String dossierId,
    String tabKey = 'Plans',
    required int sourcePageNumber,
    String? previewDataUrl,
  }) async {
    lastDuplicatePreview = previewDataUrl;
    lastDuplicateSource = sourcePageNumber;
    final next = drawings.keys.fold<int>(0, (a, b) => a > b ? a : b) + 1;
    drawings[next] =
        drawings[sourcePageNumber] ??
        '{"format":"plan_canvas_v1","strokes":[]}';
    phases[next] = phases[sourcePageNumber];
    return next;
  }

  @override
  Future<String?> fetchNoteDrawingJson({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
    String? dossierId,
  }) async => drawings[pageNumber];

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
    writes++;
    drawings[pageNumber] = drawingJson;
  }

  @override
  Future<void> setNotePlanPhase({
    required String patientId,
    required String tabKey,
    required int pageNumber,
    required PlanPhase? phase,
  }) async {
    phases[pageNumber] = phase;
  }

  @override
  Future<PlanPhase?> fetchNotePlanPhase({
    required String patientId,
    required String tabKey,
    int pageNumber = 0,
  }) async => phases[pageNumber];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Dossier _fictionalDossier() => Dossier(
  id: 'fictional-dossier',
  patient: Patient(
    id: 'fictional-patient',
    firstName: 'Élodie',
    lastName: 'DUPONT',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.values.first,
  ergoId: '',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.OTHER,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
  createdAt: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final validStroke = {
    'tool': 'pen',
    'color': 4279900698,
    'size': 2,
    'points': [
      [10, 10],
      [30, 30],
    ],
  };
  final unsafeStrokes = <String, Object?>{
    'unknown tool': {...validStroke, 'tool': 'old-dimension'},
    'non-object stroke': 42,
    'malformed coordinate': {
      ...validStroke,
      'points': [
        [10, 'bad'],
      ],
    },
    'filtered point': {
      ...validStroke,
      'points': [
        [10, 10],
        null,
      ],
    },
    'extra coordinate': {
      ...validStroke,
      'points': [
        [10, 10, 99],
      ],
    },
    'unrecognized stroke metadata': {
      ...validStroke,
      'pressure': [0.4, 0.8],
    },
    'malformed erasure': {
      ...validStroke,
      'erasures': [
        {
          'points': [
            [10],
          ],
          'size': 3,
        },
      ],
    },
    'unrecognized erasure metadata': {
      ...validStroke,
      'erasures': [
        {
          'points': [
            [10, 10],
          ],
          'pressure': 0.5,
        },
      ],
    },
    'missing tool': {
      'points': [
        [10, 10],
      ],
    },
  };
  for (final entry in unsafeStrokes.entries) {
    testWidgets('protects the entire v1 page with ${entry.key}', (
      tester,
    ) async {
      final service = _PlansDataService();
      final raw = jsonEncode({
        'format': 'plan_canvas_v1',
        'strokes': [validStroke, entry.value],
      });
      service.drawings[0] = raw;
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => 'previous-preview',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Plan ancien conservé en lecture seule'),
        findsOneWidget,
      );
      expect(find.byTooltip('Crayon'), findsNothing);
      await tester.dragFrom(const Offset(600, 400), const Offset(30, 30));
      await tester.pump(const Duration(seconds: 1));
      expect(service.writes, 0);
      expect(service.drawings[0], raw);
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(service.drawings[1], raw);
      expect(service.lastDuplicatePreview, isNull);
    });
  }

  testWidgets(
    'protected-image duplication never reuses the previous editable canvas preview',
    (tester) async {
      final service = _PlansDataService();
      service.drawings[0] = jsonEncode({
        'format': 'plan_canvas_v1',
        'strokes': [validStroke],
      });
      service.drawings[1] =
          '{"format":"historical-raster","reference":"fictional-image"}';
      var previewCalls = 0;
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async {
                previewCalls++;
                return 'old-page-preview';
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('Crayon'), findsOneWidget);
      await tester.tap(find.text('Scénario 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(service.lastDuplicateSource, 1);
      expect(service.lastDuplicatePreview, isNull);
      expect(previewCalls, 0);
      expect(service.drawings[2], service.drawings[1]);
    },
  );

  testWidgets(
    'an unknown historical drawing is never exposed as an empty editable canvas',
    (tester) async {
      final service = _PlansDataService();
      const legacy =
          '{"format":"historical-raster","reference":"fictional-archive"}';
      service.drawings[0] = legacy;
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Plan ancien conservé en lecture seule'),
        findsOneWidget,
      );
      expect(find.byTooltip('Crayon'), findsNothing);
      expect(service.drawings[0], legacy);
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(service.drawings[1], legacy);
      expect(
        find.text('Plan ancien conservé en lecture seule'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'gaps and high page numbers reopen without writes or renumbering',
    (tester) async {
      final service = _PlansDataService();
      service.drawings[125] =
          '{"format":"plan_canvas_v1","pageKind":"blank","strokes":[]}';
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page libre 1'), findsOneWidget);
      expect(service.drawings.keys.toList(), [125]);
      await tester.tap(find.text('Page libre 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip("Plus d'actions"));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(service.drawings.keys.toList(), [125, 126]);
      expect(service.drawings[126], service.drawings[125]);
    },
  );

  testWidgets(
    'duplicate copies the current drawing rather than the before plan',
    (tester) async {
      final service = _PlansDataService();
      service.drawings[0] =
          '{"format":"plan_canvas_v1","strokes":['
          '{"tool":"pen","color":4279900698,"size":2,'
          '"points":[[40,40],[60,60]]}]}';
      service.drawings[1] =
          '{"format":"plan_canvas_v1","strokes":['
          '{"tool":"rect","color":4279900698,"size":2,'
          '"points":[[100,100],[180,150]]}]}';
      service.phases[1] = PlanPhase.apres;
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Scénario 1'));
      await tester.tap(find.text('Scénario 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Plus d\'actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();

      final copied = jsonDecode(service.drawings[2]!) as Map<String, dynamic>;
      expect((copied['strokes'] as List).single['tool'], 'rect');
      expect(service.phases[2], PlanPhase.apres);
    },
  );

  testWidgets(
    'blank pages stay independent; scenario and duplicate keep their source',
    (tester) async {
      final service = _PlansDataService();
      await tester.binding.setSurfaceSize(const Size(1200, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> add(String label) async {
        await tester.tap(find.byTooltip('Ajouter une page'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      await add('Page vide indépendante');
      expect(find.text('Page libre 1'), findsOneWidget);
      expect((jsonDecode(service.drawings[1]!) as Map)['pageKind'], 'blank');
      expect(service.phases[1], isNull);

      await add('Scénario 1');
      expect(find.text('Scénario 1'), findsOneWidget);
      expect(
        (jsonDecode(service.drawings[2]!) as Map).containsKey('pageKind'),
        isFalse,
      );
      expect(service.phases[2], PlanPhase.apres);

      await tester.tap(find.byTooltip('Plus d\'actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(find.text('Scénario 2'), findsOneWidget);
      expect(service.drawings[3], service.drawings[2]);
      expect(service.phases[3], PlanPhase.apres);

      await tester.tap(find.text('Page libre 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Plus d\'actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dupliquer cette page'));
      await tester.pumpAndSettle();
      expect(find.text('Page libre 2'), findsOneWidget);
      expect((jsonDecode(service.drawings[4]!) as Map)['pageKind'], 'blank');
      expect(service.phases[4], isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlansTab(
              dossier: _fictionalDossier(),
              dataService: service,
              previewDataUrlBuilder: () async => null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Page libre 1'), findsOneWidget);
      expect(find.text('Scénario 1'), findsOneWidget);
      expect(find.text('Scénario 2'), findsOneWidget);
      expect(find.text('Page libre 2'), findsOneWidget);

      // A missing number never causes the remaining pages to be rewritten.
      expect(service.drawings.keys.toList(), [1, 2, 3, 4]);
    },
  );
}
