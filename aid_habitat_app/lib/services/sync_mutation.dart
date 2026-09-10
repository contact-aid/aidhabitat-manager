import 'dart:convert';
import 'dart:math';

String newSyncWriteId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Coalesces edits without treating an already edited local value as a new
/// server baseline. Missing historical values deliberately remain unknown.
Map<String, dynamic> buildSyncMutation({
  required String idKey,
  required String entityId,
  required Map<String, dynamic> updates,
  required Map<String, dynamic> baseValues,
  required String? expectedUpdatedAt,
  Map<String, dynamic>? previous,
}) {
  final previousUpdates =
      (previous?['updates'] as Map?)?.cast<String, dynamic>() ?? {};
  final previousGuard = (previous?['concurrency'] as Map?)
      ?.cast<String, dynamic>();
  if (previousGuard != null && previousGuard['version'] != 1) {
    throw StateError('Unsupported queued mutation version');
  }
  final previousBase =
      (previousGuard?['baseValues'] as Map?)?.cast<String, dynamic>() ?? {};
  final combinedUpdates = {...previousUpdates, ...updates};
  final combinedBase = <String, dynamic>{};
  for (final key in combinedUpdates.keys) {
    if (previousUpdates.containsKey(key)) {
      if (previousBase.containsKey(key)) combinedBase[key] = previousBase[key];
    } else if (baseValues.containsKey(key)) {
      combinedBase[key] = baseValues[key];
    }
  }
  // Copy through JSON so later mutation of a form's nested map/list cannot
  // change the captured reference before it is sealed in SQLite.
  return jsonDecode(
        jsonEncode({
          idKey: entityId,
          'updates': combinedUpdates,
          if (previous?.containsKey('conflict') == true)
            'conflict': previous!['conflict'],
          'concurrency': {
            'version': 1,
            'writeId': newSyncWriteId(),
            'baseValues': combinedBase,
            'expectedUpdatedAt': previous == null
                ? expectedUpdatedAt
                : previousGuard?['expectedUpdatedAt'],
          },
        }),
      )
      as Map<String, dynamic>;
}

bool _equalJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equalJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equalJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

class SyncMergePlan {
  const SyncMergePlan({required this.updates, required this.conflictingFields});

  /// Proposed patch, not a replacement of the whole remote entity.
  final Map<String, dynamic> updates;
  final List<String> conflictingFields;
  bool get canApplyAutomatically => conflictingFields.isEmpty;
}

/// Three-way comparison of canonical API fields. Structured fields are atomic:
/// arrays must never be merged by position (occupants can be reordered).
/// The caller must apply NOTHING if [SyncMergePlan.canApplyAutomatically] is
/// false, and must use a server-side version condition when applying a plan.
SyncMergePlan planSyncMerge({
  required Map<String, dynamic> baseValues,
  required Map<String, dynamic> updates,
  required Map<String, dynamic> remoteValues,
}) {
  final patch = <String, dynamic>{};
  final conflicts = <String>[];
  for (final entry in updates.entries) {
    final key = entry.key;
    if (!remoteValues.containsKey(key)) {
      conflicts.add(key);
    } else if (_equalJson(remoteValues[key], entry.value)) {
      // Already applied (e.g. a successful request whose response was lost).
      continue;
    } else if (!baseValues.containsKey(key)) {
      conflicts.add(key);
    } else if (_equalJson(baseValues[key], entry.value)) {
      // The local edit was undone; retain the remote change.
      continue;
    } else if (_equalJson(baseValues[key], remoteValues[key])) {
      patch[key] = entry.value;
    } else {
      conflicts.add(key);
    }
  }
  return SyncMergePlan(updates: patch, conflictingFields: conflicts);
}
