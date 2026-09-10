import 'dart:convert';

const int visitRecommendationsProtocolVersion = 1;

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

List<Map<String, dynamic>> _cloneItems(Iterable<Map<String, dynamic>> items) {
  return items
      .map(
        (item) => (jsonDecode(jsonEncode(item)) as Map).cast<String, dynamic>(),
      )
      .toList(growable: false);
}

bool _isDraft(Map<String, dynamic> item) =>
    (item['wikiItemId']?.toString() ?? '').trim().isEmpty;

bool _hasLocalWikiDraft(Map<String, dynamic> item) =>
    (item['wikiItemId']?.toString() ?? '').trim().toLowerCase().startsWith(
      'local_draft_',
    );

bool _isLocalOnly(Map<String, dynamic> item) =>
    _isDraft(item) || _hasLocalWikiDraft(item);

class VisitRecommendationsPublicationPlan {
  const VisitRecommendationsPublicationPlan({
    required this.localItems,
    required this.drafts,
    required this.publishedItems,
    required this.shouldEnqueue,
    required this.envelope,
  });

  /// The exact local list. Drafts are never removed to prepare a publication.
  final List<Map<String, dynamic>> localItems;
  final List<Map<String, dynamic>> drafts;
  final List<Map<String, dynamic>> publishedItems;
  final bool shouldEnqueue;

  /// Null when the change is draft-only and there is no published state to
  /// withdraw. Otherwise this is the complete replacement request.
  final Map<String, dynamic>? envelope;
}

class VisitRecommendationsWikiRemap {
  const VisitRecommendationsWikiRemap({
    required this.items,
    required this.changed,
  });

  final List<Map<String, dynamic>> items;
  final bool changed;
}

/// Pure helper for the transaction that acknowledges creation of a wiki item.
/// Queue management remains the caller's responsibility: a running publication
/// must stay immutable, and a changed list gets a new publication intention.
VisitRecommendationsWikiRemap remapVisitRecommendationWikiReference({
  required List<Map<String, dynamic>> items,
  required String oldWikiItemId,
  required String newWikiItemId,
}) {
  final oldId = oldWikiItemId.trim();
  final newId = newWikiItemId.trim();
  if (oldId.isEmpty ||
      newId.isEmpty ||
      _hasLocalWikiDraft({'wikiItemId': newId})) {
    throw ArgumentError(
      'A local source id and a final remote wiki id are required',
    );
  }

  var changed = false;
  final remapped = _cloneItems(items)
      .map((item) {
        if ((item['wikiItemId']?.toString() ?? '').trim() != oldId) return item;
        changed = true;
        return <String, dynamic>{...item, 'wikiItemId': newId};
      })
      .toList(growable: false);

  return VisitRecommendationsWikiRemap(items: remapped, changed: changed);
}

/// Separates local drafts from the authoritative published snapshot.
///
/// [hadPublishedItems] must describe the last local published baseline, before
/// applying [items]. [hasPendingPublication] covers a replacement already in
/// the durable queue. A resulting empty published list is enqueued when either
/// flag is true so an intentional remote deletion is not mistaken for a no-op.
///
/// Deliberately no local wiki-cache argument is accepted: linked candidates
/// must reach the server, whose authoritative library validation decides
/// whether a link is stale.
VisitRecommendationsPublicationPlan planVisitRecommendationsPublication({
  required List<Map<String, dynamic>> items,
  required bool hadPublishedItems,
  required bool hasPendingPublication,
  required bool remoteSnapshotExists,
  required String writeId,
  String? remoteRevision,
}) {
  final localItems = _cloneItems(items);
  final drafts = _cloneItems(localItems.where(_isLocalOnly));
  final publishedItems = _cloneItems(
    localItems.where((item) => !_isLocalOnly(item)),
  );
  final shouldEnqueue =
      publishedItems.isNotEmpty || hadPublishedItems || hasPendingPublication;

  if (!shouldEnqueue) {
    return VisitRecommendationsPublicationPlan(
      localItems: localItems,
      drafts: drafts,
      publishedItems: publishedItems,
      shouldEnqueue: false,
      envelope: null,
    );
  }

  final normalizedWriteId = writeId.trim();
  if (!_uuidPattern.hasMatch(normalizedWriteId)) {
    throw ArgumentError.value(writeId, 'writeId', 'A stable UUID is required');
  }

  final normalizedRevision = remoteRevision?.trim();
  if (remoteSnapshotExists &&
      (normalizedRevision == null ||
          !_uuidPattern.hasMatch(normalizedRevision))) {
    throw StateError(
      'The remote recommendation revision must be pulled before publication',
    );
  }
  if (!remoteSnapshotExists && normalizedRevision != null) {
    throw StateError('A revision cannot exist without a remote snapshot');
  }
  if (normalizedRevision == normalizedWriteId) {
    throw ArgumentError.value(
      writeId,
      'writeId',
      'The write UUID must advance the remote revision',
    );
  }

  return VisitRecommendationsPublicationPlan(
    localItems: localItems,
    drafts: drafts,
    publishedItems: publishedItems,
    shouldEnqueue: true,
    envelope: <String, dynamic>{
      'protocolVersion': visitRecommendationsProtocolVersion,
      'writeId': normalizedWriteId,
      'expectedRevision': normalizedRevision,
      'items': _cloneItems(publishedItems),
    },
  );
}

/// Applies a pulled published snapshot without allowing it to erase drafts.
List<Map<String, dynamic>> mergePublishedRecommendationsWithLocalDrafts({
  required List<Map<String, dynamic>> remotePublishedItems,
  required List<Map<String, dynamic>> localItems,
}) {
  final invalidRemoteDraft = remotePublishedItems.any(_isDraft);
  if (invalidRemoteDraft) {
    throw const FormatException(
      'A published recommendation snapshot cannot contain drafts',
    );
  }

  return <Map<String, dynamic>>[
    ..._cloneItems(remotePublishedItems),
    ..._cloneItems(localItems.where(_isLocalOnly)),
  ];
}
