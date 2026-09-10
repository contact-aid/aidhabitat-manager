import 'package:aid_habitat_app/services/visit_recommendations_publication.dart';
import 'package:flutter_test/flutter_test.dart';

const revision = '00000000-0000-4000-8000-000000000001';
const writeId = '00000000-0000-4000-8000-000000000002';

Map<String, dynamic> item(String id, {String wikiItemId = ''}) => {
  'id': id,
  'wikiItemId': wikiItemId,
  'customTitle': 'Titre $id',
  'note': 'Note $id',
};

void main() {
  group('agent2 recommendation publication planning', () {
    test(
      'wiki acknowledgement remaps local references without mutating input',
      () {
        final pending = item('pending', wikiItemId: 'local_draft_42');
        final untouched = item('published', wikiItemId: 'wiki-existing');
        final source = [pending, untouched];

        final result = remapVisitRecommendationWikiReference(
          items: source,
          oldWikiItemId: 'local_draft_42',
          newWikiItemId: 'wiki-created',
        );

        expect(result.changed, isTrue);
        expect(result.items[0]['wikiItemId'], 'wiki-created');
        expect(result.items[1], untouched);
        expect(source[0]['wikiItemId'], 'local_draft_42');
      },
    );

    test('wiki acknowledgement reports no-op when no reference matches', () {
      final source = [item('published', wikiItemId: 'wiki-existing')];

      final result = remapVisitRecommendationWikiReference(
        items: source,
        oldWikiItemId: 'local_draft_42',
        newWikiItemId: 'wiki-created',
      );

      expect(result.changed, isFalse);
      expect(result.items, source);
    });

    test('drafts alone remain local without creating a remote mutation', () {
      final draft = item('draft-1');

      final plan = planVisitRecommendationsPublication(
        items: [draft],
        hadPublishedItems: false,
        hasPendingPublication: false,
        remoteSnapshotExists: false,
        writeId: '',
      );

      expect(plan.shouldEnqueue, isFalse);
      expect(plan.envelope, isNull);
      expect(plan.localItems, [draft]);
      expect(plan.drafts, [draft]);
      expect(plan.publishedItems, isEmpty);
    });

    test(
      'draft-only replacement publishes an empty list to delete old items',
      () {
        final draft = item('draft-1');

        final plan = planVisitRecommendationsPublication(
          items: [draft],
          hadPublishedItems: true,
          hasPendingPublication: false,
          remoteSnapshotExists: true,
          remoteRevision: revision,
          writeId: writeId,
        );

        expect(plan.shouldEnqueue, isTrue);
        expect(plan.envelope?['items'], isEmpty);
        expect(plan.envelope?['expectedRevision'], revision);
        expect(plan.localItems, [draft]);
      },
    );

    test(
      'an empty replacement can intentionally delete all published items',
      () {
        final plan = planVisitRecommendationsPublication(
          items: const [],
          hadPublishedItems: true,
          hasPendingPublication: false,
          remoteSnapshotExists: true,
          remoteRevision: revision,
          writeId: writeId,
        );

        expect(plan.shouldEnqueue, isTrue);
        expect(plan.envelope?['items'], isEmpty);
      },
    );

    test('linked candidates are not filtered through a local wiki cache', () {
      final staleCandidate = item('linked-1', wikiItemId: 'wiki-not-local');

      final plan = planVisitRecommendationsPublication(
        items: [staleCandidate],
        hadPublishedItems: false,
        hasPendingPublication: false,
        remoteSnapshotExists: false,
        writeId: writeId,
      );

      expect(plan.envelope?['items'], [staleCandidate]);
    });

    test('temporary local wiki ids remain local until atomically remapped', () {
      final pendingWikiItem = item(
        'linked-pending',
        wikiItemId: 'local_draft_42',
      );

      final plan = planVisitRecommendationsPublication(
        items: [pendingWikiItem],
        hadPublishedItems: false,
        hasPendingPublication: false,
        remoteSnapshotExists: false,
        writeId: '',
      );

      expect(plan.shouldEnqueue, isFalse);
      expect(plan.localItems, [pendingWikiItem]);
      expect(plan.drafts, [pendingWikiItem]);
      expect(plan.publishedItems, isEmpty);
    });

    test('a pending publication can be replaced by an empty intention', () {
      final plan = planVisitRecommendationsPublication(
        items: const [],
        hadPublishedItems: false,
        hasPendingPublication: true,
        remoteSnapshotExists: false,
        writeId: writeId,
      );

      expect(plan.shouldEnqueue, isTrue);
      expect(plan.envelope?['expectedRevision'], isNull);
      expect(plan.envelope?['items'], isEmpty);
    });

    test(
      'publication fails closed when an existing snapshot has no revision',
      () {
        expect(
          () => planVisitRecommendationsPublication(
            items: [item('linked-1', wikiItemId: 'wiki-1')],
            hadPublishedItems: true,
            hasPendingPublication: false,
            remoteSnapshotExists: true,
            writeId: writeId,
          ),
          throwsStateError,
        );
      },
    );

    test('pull replaces published items but preserves every local draft', () {
      final draftOne = item('draft-1');
      final draftTwo = item('draft-2');
      final oldPublished = item('old', wikiItemId: 'wiki-old');
      final remote = item('remote', wikiItemId: 'wiki-new');

      final merged = mergePublishedRecommendationsWithLocalDrafts(
        remotePublishedItems: [remote],
        localItems: [oldPublished, draftOne, draftTwo],
      );

      expect(merged, [remote, draftOne, draftTwo]);
    });

    test('a malformed remote draft is rejected instead of merged', () {
      expect(
        () => mergePublishedRecommendationsWithLocalDrafts(
          remotePublishedItems: [item('remote-draft')],
          localItems: const [],
        ),
        throwsFormatException,
      );
    });
  });
}
