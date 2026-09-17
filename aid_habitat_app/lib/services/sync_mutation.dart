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
            if (previousGuard?['writeId'] is String)
              'predecessorWriteIds': [
                previousGuard!['writeId'],
                ...?previousGuard['predecessorWriteIds'] as List?,
              ].take(256).toList(),
            'baseValues': combinedBase,
            'expectedUpdatedAt': previous == null
                ? expectedUpdatedAt
                : previousGuard?['expectedUpdatedAt'],
          },
        }),
      )
      as Map<String, dynamic>;
}

String describeSyncConflict(Map<String, dynamic> payload) {
  final conflict = payload['conflict'];
  final guard = payload['concurrency'];
  if (conflict is Map && conflict['code'] == 'LOCAL_EDIT_BASE_CHANGED') {
    return 'La fiche locale a changé pendant que ce formulaire était ouvert. '
        'Vos saisies sont conservées ; comparez les valeurs avant de choisir.';
  }
  final remote = conflict is Map ? conflict['remote'] : null;
  final code = remote is Map ? remote['error'] : null;
  if (code == 'SYNC_FIELD_CONFLICT' ||
      code == 'SYNC_REMOTE_VALUES_REQUIRE_REVIEW') {
    return 'Les valeurs saisies et les valeurs du serveur ne peuvent pas être '
        'fusionnées automatiquement sans risquer un écrasement.';
  }
  final expected = guard is Map ? guard['expectedUpdatedAt'] : null;
  final actual = remote is Map ? remote['remoteUpdatedAt'] : null;
  final before = expected is String ? DateTime.tryParse(expected) : null;
  final after = actual is String ? DateTime.tryParse(actual) : null;
  if (before != null && after != null && after.isAfter(before)) {
    return 'La fiche serveur a changé depuis la version de référence de cette '
        'saisie. Cela ne permet pas de savoir quel appareil est à l’origine '
        'du changement.\nRéférence : $expected\nServeur : $actual';
  }
  if (before == null || code == 'SYNC_BASELINE_REQUIRED') {
    return 'La version de référence de cette saisie est absente ou inutilisable. '
        'Vos modifications restent sur cet appareil ; une comparaison est nécessaire.';
  }
  return 'La synchronisation a été bloquée par un contrôle de cohérence. '
      'La cause précise n’est pas disponible dans cette réponse ; vos saisies sont conservées.';
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

/// Advance only a proven successor of our own successful write. Never rebase
/// on a newly fetched remote version or merge occupant arrays by position.
Map<String, dynamic>? rebaseAcknowledgedMutation({
  required Map<String, dynamic> sent,
  required Map<String, dynamic> pending,
  required String version,
}) {
  final oldGuard = sent['concurrency'];
  final guard = pending['concurrency'];
  final oldUpdates = sent['updates'];
  final updates = pending['updates'];
  if (DateTime.tryParse(version) == null ||
      pending.containsKey('conflict') ||
      oldGuard is! Map ||
      guard is! Map ||
      oldGuard['version'] != 1 ||
      guard['version'] != 1 ||
      oldUpdates is! Map ||
      updates is! Map ||
      guard['predecessorWriteIds'] is! List ||
      !(guard['predecessorWriteIds'] as List).contains(oldGuard['writeId']) ||
      guard['expectedUpdatedAt'] != oldGuard['expectedUpdatedAt'] ||
      guard['baseValues'] is! Map ||
      oldGuard['baseValues'] is! Map) {
    return null;
  }
  final base = Map<String, dynamic>.from(guard['baseValues'] as Map);
  final oldBase = oldGuard['baseValues'] as Map;
  for (final key in oldUpdates.keys) {
    if (!updates.containsKey(key) ||
        !base.containsKey(key) ||
        !oldBase.containsKey(key) ||
        !_equalJson(base[key], oldBase[key])) {
      return null;
    }
  }
  base.addAll(Map<String, dynamic>.from(oldUpdates));
  return {
    ...pending,
    'concurrency': {
      ...Map<String, dynamic>.from(guard),
      'baseValues': base,
      'expectedUpdatedAt': version,
      'predecessorWriteIds': <String>[],
    },
  };
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
