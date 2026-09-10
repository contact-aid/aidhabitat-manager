import 'dart:convert';

const _contextSections = {'medicalContext', 'autonomy'};
final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

bool _deepEqual(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _deepEqual(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(
          a.length,
          (index) => index,
        ).every((index) => _deepEqual(a[index], b[index]));
  }
  return a == b;
}

void _validateSections(Map<String, dynamic> values, String label) {
  if (values.keys.any(
    (key) => !_contextSections.contains(key) || values[key] is! Map,
  )) {
    throw FormatException('$label contexte invalide');
  }
}

class ContextServerReference {
  const ContextServerReference({
    required this.recordId,
    required this.revision,
    this.updatedAt,
  });

  final int recordId;
  final String revision;
  final String? updatedAt;

  factory ContextServerReference.fromJson(Map<String, dynamic> json) {
    final recordId = json['recordId'];
    final revision = json['revision'];
    if (recordId is! int ||
        recordId <= 0 ||
        revision is! String ||
        !_uuidPattern.hasMatch(revision)) {
      throw const FormatException('Référence serveur contexte invalide');
    }
    return ContextServerReference(
      recordId: recordId,
      revision: revision,
      updatedAt: json['updatedAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'recordId': recordId,
    'revision': revision,
    if (updatedAt != null) 'updatedAt': updatedAt,
  };
}

class ContextMergePlan {
  const ContextMergePlan({
    required this.updates,
    required this.conflicts,
    required this.retainedRemote,
  });

  final Map<String, dynamic> updates;
  final List<String> conflicts;
  final List<String> retainedRemote;
  bool get requiresReview => conflicts.isNotEmpty || retainedRemote.isNotEmpty;
}

ContextMergePlan planContextMerge({
  required Map<String, dynamic> baseValues,
  required Map<String, dynamic> updates,
  required Map<String, dynamic> remoteValues,
}) {
  _validateSections(baseValues, 'Base');
  _validateSections(updates, 'Modification');
  _validateSections(remoteValues, 'Valeur distante');
  final patch = <String, dynamic>{};
  final conflicts = <String>[];
  final retained = <String>[];
  for (final entry in updates.entries) {
    final key = entry.key;
    if (!remoteValues.containsKey(key)) {
      conflicts.add(key);
    } else if (_deepEqual(remoteValues[key], entry.value)) {
      continue;
    } else if (!baseValues.containsKey(key)) {
      conflicts.add(key);
    } else if (_deepEqual(baseValues[key], entry.value)) {
      retained.add(key);
    } else if (_deepEqual(baseValues[key], remoteValues[key])) {
      patch[key] = entry.value;
    } else {
      conflicts.add(key);
    }
  }
  return ContextMergePlan(
    updates: Map.unmodifiable(_copyMap(patch)),
    conflicts: List.unmodifiable(conflicts),
    retainedRemote: List.unmodifiable(retained),
  );
}

class ContextConflictSnapshot {
  ContextConflictSnapshot({
    required this.remoteValues,
    required this.remoteReference,
    required this.conflictingSections,
    required this.retainedRemoteSections,
  });

  final Map<String, dynamic> remoteValues;
  final ContextServerReference remoteReference;
  final List<String> conflictingSections;
  final List<String> retainedRemoteSections;

  factory ContextConflictSnapshot.fromJson(Map<String, dynamic> json) =>
      ContextConflictSnapshot(
        remoteValues: _copyMap(
          (json['remoteValues'] as Map).cast<String, dynamic>(),
        ),
        remoteReference: ContextServerReference.fromJson(
          (json['remoteReference'] as Map).cast<String, dynamic>(),
        ),
        conflictingSections: List<String>.from(
          json['conflictingSections'] as List,
        ),
        retainedRemoteSections: List<String>.from(
          json['retainedRemoteSections'] as List,
        ),
      );

  Map<String, dynamic> toJson() => {
    'remoteValues': remoteValues,
    'remoteReference': remoteReference.toJson(),
    'conflictingSections': conflictingSections,
    'retainedRemoteSections': retainedRemoteSections,
  };
}

class ContextComparison {
  const ContextComparison({
    required this.generation,
    required this.writeId,
    required this.remoteValues,
    required this.remoteReference,
    required this.plan,
  });

  final int generation;
  final String writeId;
  final Map<String, dynamic> remoteValues;
  final ContextServerReference remoteReference;
  final ContextMergePlan plan;
}

class ContextConflictResolution {
  const ContextConflictResolution({
    required this.valuesToStoreLocally,
    required this.pendingMutation,
  });

  final Map<String, dynamic> valuesToStoreLocally;
  final ContextMutationEnvelope? pendingMutation;
}

class ContextMutationEnvelope {
  ContextMutationEnvelope._({
    required this.dossierId,
    required this.updates,
    required this.baseValues,
    required this.serverReference,
    required this.writeId,
    required this.generation,
    required this.conflict,
  });

  final String dossierId;
  final Map<String, dynamic> updates;
  final Map<String, dynamic> baseValues;
  final ContextServerReference? serverReference;
  final String writeId;
  final int generation;
  final ContextConflictSnapshot? conflict;

  factory ContextMutationEnvelope.begin({
    required String dossierId,
    required Map<String, dynamic> updates,
    required Map<String, dynamic> valuesBeforeEdit,
    required ContextServerReference? serverReference,
    required String writeId,
  }) {
    if (dossierId.trim().isEmpty || !_uuidPattern.hasMatch(writeId)) {
      throw const FormatException('Mutation contexte invalide');
    }
    _validateSections(updates, 'Modification');
    _validateSections(valuesBeforeEdit, 'Base');
    final base = <String, dynamic>{
      for (final key in updates.keys)
        if (valuesBeforeEdit.containsKey(key)) key: valuesBeforeEdit[key],
    };
    return ContextMutationEnvelope._(
      dossierId: dossierId,
      updates: Map.unmodifiable(_copyMap(updates)),
      baseValues: Map.unmodifiable(_copyMap(base)),
      serverReference: serverReference,
      writeId: writeId,
      generation: 1,
      conflict: null,
    );
  }

  factory ContextMutationEnvelope.fromJson(Map<String, dynamic> json) {
    final updates = (json['updates'] as Map).cast<String, dynamic>();
    final base = (json['baseValues'] as Map).cast<String, dynamic>();
    _validateSections(updates, 'Modification');
    _validateSections(base, 'Base');
    final dossierId = json['dossierId'];
    final writeId = json['writeId'];
    final generation = json['generation'];
    if (dossierId is! String ||
        dossierId.trim().isEmpty ||
        writeId is! String ||
        !_uuidPattern.hasMatch(writeId) ||
        generation is! int ||
        generation < 1) {
      throw const FormatException('Mutation contexte persistée invalide');
    }
    return ContextMutationEnvelope._(
      dossierId: dossierId,
      updates: Map.unmodifiable(_copyMap(updates)),
      baseValues: Map.unmodifiable(_copyMap(base)),
      serverReference: json['serverReference'] == null
          ? null
          : ContextServerReference.fromJson(
              (json['serverReference'] as Map).cast<String, dynamic>(),
            ),
      writeId: writeId,
      generation: generation,
      conflict: json['conflict'] == null
          ? null
          : ContextConflictSnapshot.fromJson(
              (json['conflict'] as Map).cast<String, dynamic>(),
            ),
    );
  }

  ContextMutationEnvelope addEdits({
    required Map<String, dynamic> updates,
    required Map<String, dynamic> valuesBeforeEdit,
    required String nextWriteId,
  }) {
    if (conflict != null) {
      throw StateError('Le conflit contexte doit être résolu explicitement.');
    }
    if (!_uuidPattern.hasMatch(nextWriteId) || nextWriteId == writeId) {
      throw const FormatException('Nouvel identifiant de mutation invalide');
    }
    _validateSections(updates, 'Modification');
    _validateSections(valuesBeforeEdit, 'Base');
    final combinedUpdates = <String, dynamic>{...this.updates, ...updates};
    final combinedBase = <String, dynamic>{};
    for (final key in combinedUpdates.keys) {
      if (this.updates.containsKey(key)) {
        if (baseValues.containsKey(key)) combinedBase[key] = baseValues[key];
      } else if (valuesBeforeEdit.containsKey(key)) {
        combinedBase[key] = valuesBeforeEdit[key];
      }
    }
    return ContextMutationEnvelope._(
      dossierId: dossierId,
      updates: Map.unmodifiable(_copyMap(combinedUpdates)),
      baseValues: Map.unmodifiable(_copyMap(combinedBase)),
      serverReference: serverReference,
      writeId: nextWriteId,
      generation: generation + 1,
      conflict: null,
    );
  }

  ContextComparison compareWith({
    required Map<String, dynamic> remoteValues,
    required ContextServerReference remoteReference,
  }) => ContextComparison(
    generation: generation,
    writeId: writeId,
    remoteValues: Map.unmodifiable(_copyMap(remoteValues)),
    remoteReference: remoteReference,
    plan: planContextMerge(
      baseValues: baseValues,
      updates: updates,
      remoteValues: remoteValues,
    ),
  );

  bool isComparisonCurrent(ContextComparison comparison) =>
      comparison.generation == generation && comparison.writeId == writeId;

  ContextMutationEnvelope recordConflict(ContextComparison comparison) {
    if (!isComparisonCurrent(comparison)) {
      throw StateError('Comparaison contexte devenue obsolète.');
    }
    if (!comparison.plan.requiresReview) {
      throw StateError('Aucun conflit contexte à enregistrer.');
    }
    return ContextMutationEnvelope._(
      dossierId: dossierId,
      updates: updates,
      baseValues: baseValues,
      serverReference: serverReference,
      writeId: writeId,
      generation: generation,
      conflict: ContextConflictSnapshot(
        remoteValues: comparison.remoteValues,
        remoteReference: comparison.remoteReference,
        conflictingSections: comparison.plan.conflicts,
        retainedRemoteSections: comparison.plan.retainedRemote,
      ),
    );
  }

  ContextConflictResolution resolveConflict({
    required Map<String, String> decisions,
    required String nextWriteId,
  }) {
    final snapshot = conflict;
    if (snapshot == null) throw StateError('Aucun conflit contexte.');
    final sectionsToDecide = {
      ...snapshot.conflictingSections,
      ...snapshot.retainedRemoteSections,
    };
    if (sectionsToDecide.any(
      (key) => decisions[key] != 'local' && decisions[key] != 'remote',
    )) {
      throw const FormatException('Décision explicite manquante.');
    }
    final localValues = <String, dynamic>{...snapshot.remoteValues};
    final retryUpdates = <String, dynamic>{
      ...compareWith(
        remoteValues: snapshot.remoteValues,
        remoteReference: snapshot.remoteReference,
      ).plan.updates,
    };
    for (final key in sectionsToDecide) {
      if (decisions[key] == 'local') {
        localValues[key] = updates[key];
        retryUpdates[key] = updates[key];
      }
    }
    final pending = retryUpdates.isEmpty
        ? null
        : ContextMutationEnvelope.begin(
            dossierId: dossierId,
            updates: retryUpdates,
            valuesBeforeEdit: snapshot.remoteValues,
            serverReference: snapshot.remoteReference,
            writeId: nextWriteId,
          );
    return ContextConflictResolution(
      valuesToStoreLocally: Map.unmodifiable(_copyMap(localValues)),
      pendingMutation: pending,
    );
  }

  Map<String, dynamic> toJson() => {
    'dossierId': dossierId,
    'updates': updates,
    'baseValues': baseValues,
    'serverReference': serverReference?.toJson(),
    'writeId': writeId,
    'generation': generation,
    if (conflict != null) 'conflict': conflict!.toJson(),
  };

  Map<String, dynamic> toRequestJson() => {
    'updates': updates,
    'concurrency': {
      'version': 1,
      'writeId': writeId,
      'reference': serverReference?.toJson(),
      'baseValues': baseValues,
    },
  };
}
