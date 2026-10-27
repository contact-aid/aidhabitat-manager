import 'dart:async';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/recommendations_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Dossier extends Fake implements Dossier {
  @override
  String get id => 'synthetic-dossier';
}

class _Repository extends Fake implements DossierRepository {
  List<VisitRecommendationItem> items = List.generate(
    3,
    (i) => VisitRecommendationItem(
      id: 'original-$i',
      wikiItemId: 'wiki-$i',
      wikiTitle: 'Original $i',
      note: 'Original description $i',
    ),
  );
  Future<List<VisitRecommendationItem>>? nextRead;
  Completer<void>? saveGate;
  int readCalls = 0;

  @override
  Future<List<VisitRecommendationItem>> fetchVisitRecommendations(String id) {
    readCalls++;
    final read = nextRead;
    nextRead = null;
    return read ?? Future.value(List.of(items));
  }

  @override
  Future<void> saveVisitRecommendations(
    String id,
    List<VisitRecommendationItem> value, {
    bool forceSync = false,
  }) async {
    final copy = List<VisitRecommendationItem>.of(value);
    if (saveGate != null) await saveGate!.future;
    items = copy;
  }
}

class _WikiRepository extends Fake implements WikiRepository {
  @override
  Future<List<WikiItem>> fetchAllItems() async => List.generate(
    4,
    (i) => WikiItem(
      id: 'added-$i',
      title: 'Addition $i',
      description: 'Description $i',
      imageUrl: '',
      category: '',
      tags: const [],
      createdAt: '',
      updatedAt: '',
    ),
  );
}

void main() {
  testWidgets('a delayed refresh cannot remove four additions already saved', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repository = _Repository();
    final wiki = _WikiRepository();
    final refresh = ValueNotifier(0);
    addTearDown(refresh.dispose);
    final controller = RecommendationsTabController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: refresh,
            builder: (_, token, _) => RecommendationsTab(
              dossier: _Dossier(),
              repository: repository,
              wikiRepository: wiki,
              controller: controller,
              externalRefreshToken: token,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final oldItems = List<VisitRecommendationItem>.of(repository.items);
    final delayedRead = Completer<List<VisitRecommendationItem>>();
    repository.nextRead = delayedRead.future;
    refresh.value++;
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('Ajouter une\npréconisation'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Addition $i').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Addition $i').last);
      await tester.pumpAndSettle();
    }
    await controller.flushPendingSave();
    expect(repository.items, hasLength(7));
    delayedRead.complete(oldItems);
    await tester.pumpAndSettle();
    final visibleCount = find.byType(DragTarget<String>).evaluate().length;
    // Leave for the library during the debounce window, then reopen the report.
    final description = find.byWidgetPredicate(
      (w) => w is TextField && w.maxLines == null && w.minLines == 2,
    );
    await tester.enterText(description.first, 'Edited after refresh');
    await tester.pumpWidget(const MaterialApp(home: Text('Library')));
    await tester.pumpAndSettle();
    expect(repository.items, hasLength(7));
    expect(visibleCount, 7);
    expect(repository.items.first.note, 'Edited after refresh');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendationsTab(
            dossier: _Dossier(),
            repository: repository,
            wikiRepository: wiki,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DragTarget<String>), findsNWidgets(7));
    expect(find.text('Edited after refresh'), findsOneWidget);
  });

  testWidgets('refresh waits for a pending description save', (tester) async {
    final repository = _Repository();
    final refresh = ValueNotifier(0);
    addTearDown(refresh.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<int>(
            valueListenable: refresh,
            builder: (_, token, _) => RecommendationsTab(
              dossier: _Dossier(),
              repository: repository,
              wikiRepository: _WikiRepository(),
              externalRefreshToken: token,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    repository.saveGate = Completer<void>();
    final description = find.byWidgetPredicate(
      (w) => w is TextField && w.maxLines == null && w.minLines == 2,
    );
    await tester.enterText(description.first, 'Personalized seat description');
    refresh.value++;
    await tester.pump();
    final readsWhileSavePending = repository.readCalls;
    repository.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(readsWhileSavePending, 1);
    expect(repository.items.first.note, 'Personalized seat description');
    expect(find.text('Personalized seat description'), findsOneWidget);
  });
}
