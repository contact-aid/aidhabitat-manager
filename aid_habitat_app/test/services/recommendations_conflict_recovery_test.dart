import 'dart:convert';
import 'package:aid_habitat_app/screens/conflict_resolution_screen.dart';
import 'package:flutter/material.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const revision = '00000000-0000-4000-8000-000000000001';
const draft = {
  'id': 'draft',
  'wikiItemId': 'local_draft_42',
  'note': 'Brouillon',
};
const localItem = {'id': 'r', 'wikiItemId': 'wiki-1', 'note': 'Local'};
const remoteItem = {'id': 'r', 'wikiItemId': 'wiki-1', 'note': 'Serveur'};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository repository;
  Future<String> payload() async => OfflineVault.instance.openString(
    (await db.query('sync_operations')).single['payload_json'] as String,
  );
  Map<String, dynamic> snapshot({bool exists = true}) => {
    'items': exists ? [remoteItem] : [],
    'snapshotExists': exists,
    'revision': exists ? revision : null,
    'updatedAt': '2026-10-12T13:00:00Z',
  };
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = DossierRepository(database: local);
    await db.insert('visit_recommendations', {
      'local_id': 'rec-1',
      'dossier_local_id': 'dossier-1',
      'items_json': jsonEncode([localItem, draft]),
      'sync_state': 'conflict',
      'updated_at': '2026-09-01T12:00:00Z',
    });
    await db.insert('sync_operations', {
      'id': 'legacy-op',
      'entity_type': 'visit_recommendations',
      'entity_local_id': 'dossier-1',
      'operation_type': 'update',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({
          'dossierId': 'dossier-1',
          'items': [localItem],
        }),
      ),
      'status': 'conflict',
      'attempt_count': 1,
      'last_error': 'legacy',
      'created_at': '2026-09-01T12:00:00Z',
      'updated_at': '2026-09-01T12:00:00Z',
    });
  });
  tearDown(() async => db.close());
  for (final width in [390.0, 1024.0]) {
    testWidgets('recommendations comparison is readable at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = await tester.runAsync(() async {
        await repository.mergeRemoteDossierPayloads([
          {
            'id': 'dossier-1',
            'updatedAt': '2026-10-01T10:00:00Z',
            'patient': {
              'id': 'patient-1',
              'firstName': 'Test',
              'lastName': 'Exemple',
            },
            'housing': {},
          },
        ]);
        final dossier = (await repository.fetchDossierById('dossier-1'))!;
        final reviews = await repository.reviewVisitRecommendationsConflict(
          'dossier-1',
          snapshot(),
        );
        return (dossier, reviews);
      });
      final (dossier, reviews) = prepared!;
      var resolved = false;
      final choices = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ConflictResolutionScreen(
            localDossier: dossier,
            loadReviews: () async => reviews,
            resolveReview: (review, keepLocal) async {
              choices.add(keepLocal);
            },
            onResolved: () {
              resolved = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Préconisations'), findsOneWidget);
      expect(find.text('Cet appareil (2)'), findsOneWidget);
      expect(find.text('Serveur (1)'), findsOneWidget);
      expect(find.textContaining('Local'), findsOneWidget);
      expect(find.textContaining('Brouillon'), findsOneWidget);
      expect(find.textContaining('wiki-1'), findsNothing);
      await tester.ensureVisible(find.text('Conserver mes changements'));
      await tester.tap(find.text('Conserver mes changements'));
      await tester.pumpAndSettle();
      expect(resolved, isTrue);
      expect(choices, [true]);
      expect(tester.takeException(), isNull);
    });
  }
  test(
    'legacy review is read-only; local choice uses reviewed revision',
    () async {
      final before = await payload();
      final review = (await repository.reviewVisitRecommendationsConflict(
        'dossier-1',
        snapshot(),
      )).single;
      expect(await payload(), before);
      expect(review.localValues['items'], [localItem, draft]);
      expect(review.remoteValues['items'], [remoteItem]);
      await repository.resolveReviewedConflict(review, keepLocal: true);
      final envelope = jsonDecode(await payload())['envelope'] as Map;
      expect(envelope['expectedRevision'], revision);
      expect(envelope['protocolVersion'], 1);
      expect(envelope['items'], [localItem]);
      expect(envelope['writeId'], isNot(revision));
      expect((await db.query('sync_operations')).single['status'], 'pending');
      expect(
        jsonDecode(
          (await db.query('visit_recommendations')).single['items_json']
              as String,
        ),
        [localItem, draft],
      );
      expect(await db.query('sync_conflict_history'), hasLength(1));
    },
  );
  test(
    'remote choice keeps local wiki drafts and archives rejected mutation',
    () async {
      final review = (await repository.reviewVisitRecommendationsConflict(
        'dossier-1',
        snapshot(),
      )).single;
      await repository.resolveReviewedConflict(review, keepLocal: false);
      expect(
        jsonDecode(
          (await db.query('visit_recommendations')).single['items_json']
              as String,
        ),
        [remoteItem, draft],
      );
      expect((await db.query('sync_operations')).single['status'], 'completed');
      expect(await db.query('sync_conflict_history'), hasLength(1));
    },
  );
  test(
    'absent snapshot creates conditionally with null expected revision',
    () async {
      final review = (await repository.reviewVisitRecommendationsConflict(
        'dossier-1',
        snapshot(exists: false),
      )).single;
      await repository.resolveReviewedConflict(review, keepLocal: true);
      expect(
        jsonDecode(await payload())['envelope']['expectedRevision'],
        isNull,
      );
    },
  );
  test('review refuses an edit made while comparison was open', () async {
    final review = (await repository.reviewVisitRecommendationsConflict(
      'dossier-1',
      snapshot(),
    )).single;
    await db.update('visit_recommendations', {
      'items_json': jsonEncode([draft]),
    });
    await expectLater(
      repository.resolveReviewedConflict(review, keepLocal: true),
      throwsStateError,
    );
    expect((await db.query('sync_operations')).single['status'], 'conflict');
    expect(await db.query('sync_conflict_history'), isEmpty);
  });
  test(
    'legacy conflict never adopts server values based on timestamps',
    () async {
      expect(
        await repository.resolveVisitRecommendationsByLatestEdit(
          'dossier-1',
          snapshot(),
        ),
        isFalse,
      );
      expect((await db.query('sync_operations')).single['status'], 'conflict');
    },
  );
  test('missing revision and competing edits require a new review', () async {
    await expectLater(
      repository.reviewVisitRecommendationsConflict('dossier-1', {
        ...snapshot(),
        'revision': null,
      }),
      throwsStateError,
    );
    final review = (await repository.reviewVisitRecommendationsConflict(
      'dossier-1',
      snapshot(),
    )).single;
    final op =
        Map<String, Object?>.from((await db.query('sync_operations')).single)
          ..['id'] = 'other-op'
          ..['status'] = 'pending';
    await db.insert('sync_operations', op);
    await expectLater(
      repository.resolveReviewedConflict(review, keepLocal: true),
      throwsStateError,
    );
    expect(await db.query('sync_conflict_history'), isEmpty);
  });
}
