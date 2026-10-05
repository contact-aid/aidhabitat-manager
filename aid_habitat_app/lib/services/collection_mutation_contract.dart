const collectionMutationContract = 'collections-v2';

/// Persist this capability with a newly authored operation, never in transport.
/// Legacy queued edits need explicit review before acquiring it.
bool hasCollectionUpdates(String entityType, Map updates) {
  final keys = switch (entityType) {
    'patient' => const {'occupants', 'dependenceTxt'},
    'housing' => const {
      'roomsBreakdown',
      'basement',
      'rdc',
      'floor',
      'secondFloor',
      'thirdFloor',
    },
    'diagnostic_sanitaires' => const {'sdbInstances', 'wcInstances'},
    _ => const <String>{},
  };
  return keys.any(updates.containsKey);
}

void stampNewCollectionMutation(
  String entityType,
  Map<String, dynamic> payload,
  Map<String, dynamic>? previous,
) {
  final updates = payload['updates'];
  final guard = payload['concurrency'];
  if (updates is! Map ||
      guard is! Map ||
      !hasCollectionUpdates(entityType, updates)) {
    return;
  }
  final previousGuard = previous?['concurrency'];
  if (previous == null ||
      (previousGuard is Map &&
          previousGuard['collectionContract'] == collectionMutationContract)) {
    guard['collectionContract'] = collectionMutationContract;
  }
}
