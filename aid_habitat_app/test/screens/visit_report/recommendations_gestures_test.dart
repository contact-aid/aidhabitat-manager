import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/recommendations_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dossier extends Fake implements Dossier {
  @override
  String get id => 'synthetic-dossier';
}

class _Repository extends Fake implements DossierRepository {
  @override
  Future<List<VisitRecommendationItem>> fetchVisitRecommendations(
    String id,
  ) async => [
    const VisitRecommendationItem(
      id: 'one',
      wikiTitle: 'Synthetic',
      note: 'First line\nSecond line\nThird line\nFourth line',
    ),
  ];

  @override
  Future<void> saveVisitRecommendations(
    String id,
    List<VisitRecommendationItem> items, {
    bool forceSync = false,
  }) async {}
}

void main() {
  testWidgets(
    'description stays two lines and drag is confined to the image and tab',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (context, show, child) => show
                  ? RecommendationsTab(
                      dossier: _Dossier(),
                      repository: _Repository(),
                    )
                  : const Text('Other tab'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final description = find.byWidgetPredicate(
        (w) => w is TextField && w.maxLines == 2 && w.minLines == 2,
      );
      expect(description, findsOneWidget);
      expect(
        find.ancestor(
          of: description,
          matching: find.byType(LongPressDraggable<String>),
        ),
        findsNothing,
      );
      final height = tester.getSize(description).height;
      await tester.enterText(
        description,
        List.filled(12, 'More text').join('\n'),
      );
      await tester.pump();
      expect(tester.getSize(description).height, height);
      final image = find.byType(LongPressDraggable<String>);
      expect(image, findsOneWidget);
      final gesture = await tester.startGesture(tester.getCenter(image));
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(30, 30));
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(4));
      expect(find.byType(LongPressDraggable<String>), findsOneWidget);
      visible.value = false;
      await tester.pump();
      expect(find.text('Other tab'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
