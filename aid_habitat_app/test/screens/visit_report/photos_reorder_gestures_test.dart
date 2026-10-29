import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/models/visit_report_categories.dart';
import 'package:aid_habitat_app/screens/visit_report/photos_tab.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Patient extends Fake implements Patient {
  @override
  String get id => 'synthetic-patient';
}

class _Dossier extends Fake implements Dossier {
  @override
  Patient get patient => _Patient();
}

class _Photos extends Fake implements DataService {
  _Photos(String tag, int count)
    : photos = List.generate(
        count,
        (i) => DocItem(
          id: 'plan-$i',
          type: 'image',
          name: 'plan-$i.png',
          title: 'Plan $i',
          date: '2026-10-29',
          tags: [tag],
          categoryOrder: i,
        ),
      );
  List<DocItem> photos;
  final saved = <List<String>>[];
  @override
  Future<List<DocItem>> fetchDocuments(String patientId) async => photos;
  @override
  Future<bool> refreshDocumentsFromRemote(String patientId) async => false;
  @override
  Future<void> reorderVisitCategoryDocuments({
    required List<String> orderedDocumentIds,
  }) async {
    saved.add(List.of(orderedDocumentIds));
    photos = [
      for (var i = 0; i < orderedDocumentIds.length; i++)
        photos
            .firstWhere((p) => p.id == orderedDocumentIds[i])
            .copyWith(categoryOrder: i),
    ];
  }
}

void main() {
  for (final (tag, count, targetIndex, accept) in [
    (kPhotoTagPlanAvant, 8, 2, true),
    (kPhotoTagPlanAvant, 8, 7, true),
    (kPhotoTagPlanApres, 3, 2, true),
    (kPhotoTagPlanAvant, 8, 2, false),
  ]) {
    testWidgets('$count plans: target $targetIndex, accepted $accept', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = _Photos(tag, count);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PhotosTab(dossier: _Dossier(), dataService: service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('photo_position_plan-0'));
      final target = find.byKey(ValueKey('photo_position_plan-$targetIndex'));
      await tester.ensureVisible(first);
      await tester.pumpAndSettle();
      final start = tester.getTopLeft(first) + const Offset(20, 20);
      final end = tester.getTopLeft(target) + const Offset(20, 20);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(5, 0));
      await tester.pump();
      await gesture.moveTo(end);
      await tester.pumpAndSettle();
      // The preview places the dragged tile under the pointer. The child
      // rejects itself; the section must still accept the drop.
      await gesture.moveBy(const Offset(1, 0));
      await tester.pump();
      if (!accept) {
        await gesture.moveTo(const Offset(2, 2));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      if (accept) {
        expect(service.saved, hasLength(1));
        final expected = List.generate(count, (i) => 'plan-$i');
        expected.insert(targetIndex, expected.removeAt(0));
        expect(service.saved.single, expected);
      } else {
        expect(service.saved, isEmpty);
        expect(
          tester.getTopLeft(first).dx,
          lessThan(tester.getTopLeft(target).dx),
        );
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
