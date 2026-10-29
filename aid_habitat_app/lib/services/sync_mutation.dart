import 'dart:convert';
import 'dart:math';
import 'context_sync_protocol.dart';

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
          if (previous?['retryMutation'] is Map)
            'retryMutation': previous!['retryMutation'],
          if (previous?.containsKey('conflict') == true)
            'conflict': previous!['conflict'],
          'concurrency': {
            'version': 1,
            'writeId': newSyncWriteId(),
            if (previousGuard?['createIfAbsent'] == true)
              'createIfAbsent': true,
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
  if (code == 'SYNC_HOUSING_WRITE_SUPERSEDED') {
    return 'Le logement a changé depuis cet envoi. Comparez les versions '
        'avant de remplacer une correction plus récente. Vos saisies sont conservées.';
  }
  if (code == 'COLLECTION_CLIENT_UPGRADE_REQUIRED') {
    return 'Cette saisie vient d’une ancienne version. Vos valeurs sont conservées. '
        'Comparez-les dans la nouvelle application puis choisissez explicitement '
        'la version à conserver.';
  }
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
  Map<String, dynamic>? contextReference;
  final context = oldGuard is Map && oldGuard.containsKey('reference');
  if (context) {
    try {
      contextReference = ContextServerReference.fromJson(
        (jsonDecode(version) as Map).cast<String, dynamic>(),
      ).toJson();
    } catch (_) {
      return null;
    }
    if (guard is! Map ||
        !guard.containsKey('reference') ||
        !_equalJson(oldGuard['reference'], guard['reference'])) {
      return null;
    }
  }
  if ((!context && DateTime.tryParse(version) == null) ||
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
    if ((context || oldGuard['createIfAbsent'] == true) &&
        updates.containsKey(key) &&
        !base.containsKey(key) &&
        !oldBase.containsKey(key)) {
      continue;
    }
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
    'retryMutation': null,
    'concurrency': {
      ...Map<String, dynamic>.from(guard),
      'baseValues': base,
      'expectedUpdatedAt': context ? contextReference!['updatedAt'] : version,
      if (context) 'reference': contextReference,
      'predecessorWriteIds': <String>[],
      if (guard.containsKey('createIfAbsent')) 'createIfAbsent': false,
    },
  };
}

/// Advances a queued note edit only after the server has acknowledged one of
/// its own predecessors. Note revisions are UUIDs (rather than timestamps),
/// so they cannot use [rebaseAcknowledgedMutation].
///
/// The identity fields must still describe the same note and the pending
/// mutation must explicitly name the acknowledged write as a predecessor.
/// This prevents a genuine edit from another device from being mistaken for
/// a same-device autosave race.
Map<String, dynamic>? rebaseAcknowledgedNoteMutation({
  required Map<String, dynamic> sent,
  required Map<String, dynamic> pending,
  required String revision,
}) {
  final sentWriteId = sent['writeId'];
  final pendingWriteId = pending['writeId'];
  final predecessors = pending['predecessorWriteIds'];
  final uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  if (!uuid.hasMatch(revision) ||
      sentWriteId is! String ||
      pendingWriteId is! String ||
      !uuid.hasMatch(sentWriteId) ||
      !uuid.hasMatch(pendingWriteId) ||
      sentWriteId == pendingWriteId ||
      predecessors is! List ||
      !predecessors.contains(sentWriteId) ||
      pending.containsKey('conflict') ||
      pending['expectedRevision'] != sent['expectedRevision']) {
    return null;
  }

  const identityKeys = [
    'patientLocalId',
    'dossierId',
    'scopeType',
    'scopeId',
    'tabKey',
    'pageNumber',
  ];
  for (final key in identityKeys) {
    if (sent[key] != pending[key]) return null;
  }

  return {
    ...pending,
    'expectedRevision': revision,
    'predecessorWriteIds': <String>[],
  };
}

Object? canonicalOccupantValues(Object? value) {
  if (value is String) {
    try {
      value = jsonDecode(value);
    } catch (_) {
      return value;
    }
  }
  if (value is! List) return value;
  return value.map((person) {
    if (person is! Map) return person;
    final result = Map<Object?, Object?>.of(person);
    for (final key in [
      'apaGir',
      'apaDetails',
      'invalidityDetails',
      'fiscalReferenceYear',
    ]) {
      result[key] ??= '';
    }
    if (result['fiscalRevenue'] == null) result.remove('fiscalRevenue');
    return result;
  }).toList();
}

bool equivalentSyncField(String key, Object? left, Object? right) =>
    ((left == null && right == '') || (right == null && left == '')) ||
    _equalJson(
      key == 'occupants' || key == 'occupants_json'
          ? canonicalOccupantValues(left)
          : left,
      key == 'occupants' || key == 'occupants_json'
          ? canonicalOccupantValues(right)
          : right,
    );

bool canRetryOriginalOccupantConflict(Map<String, dynamic> payload) {
  final guard = payload['concurrency'];
  final conflict = payload['conflict'];
  final remote = conflict is Map ? conflict['remote'] : null;
  return payload['updates'] is Map &&
      (payload['updates'] as Map).containsKey('occupants') &&
      guard is Map &&
      guard['version'] == 1 &&
      guard['collectionContract'] == 'collections-v2' &&
      guard['baseValues'] is Map &&
      (guard['baseValues'] as Map).containsKey('occupants') &&
      guard['writeId'] is String &&
      conflict is Map &&
      conflict['code'] != 'LOCAL_EDIT_BASE_CHANGED' &&
      remote is Map &&
      const {
        'SYNC_FIELD_CONFLICT',
        'SYNC_REMOTE_VALUES_REQUIRE_REVIEW',
      }.contains(remote['error']);
}

List<({String label, Object? local, Object? remote})>?
occupantConflictDifferences(Object? local, Object? remote) {
  final left = canonicalOccupantValues(local);
  final right = canonicalOccupantValues(remote);
  if (left is! List || right is! List || left.length != right.length) {
    return null;
  }
  String identity(Map person) => jsonEncode([
    person['firstName'] ?? '',
    person['lastName'] ?? '',
    person['birthDate'] ?? '',
  ]);
  final identities = <String>{};
  final result = <({String label, Object? local, Object? remote})>[];
  const labels = {
    'apa': 'APA',
    'apaGir': 'GIR',
    'apaDetails': 'Détails APA',
    'invalidity': 'Reconnaissance d’invalidité',
    'invalidityTxt': 'Taux d’invalidité',
    'invalidityDetails': 'Détails invalidité',
    'fiscalReferenceYear': 'Année fiscale',
    'fiscalRevenue': 'Revenu fiscal',
    'homeHelp': 'Aide à domicile',
    'homeHelpTxt': 'Détails aide à domicile',
  };
  for (var index = 0; index < left.length; index++) {
    final a = left[index], b = right[index];
    if (a is! Map ||
        b is! Map ||
        identity(a) != identity(b) ||
        !identities.add(identity(a)) ||
        '${a['firstName'] ?? ''}${a['lastName'] ?? ''}'.trim().isEmpty) {
      return null;
    }
    final name = '${a['firstName'] ?? ''} ${a['lastName'] ?? ''}'.trim();
    for (final key in {...a.keys, ...b.keys}) {
      if (!_equalJson(a[key], b[key])) {
        result.add((
          label: '$name · ${labels[key] ?? key}',
          local: a[key],
          remote: b[key],
        ));
      }
    }
  }
  return result;
}

class SyncMergePlan {
  const SyncMergePlan({required this.updates, required this.conflictingFields});

  /// Proposed patch, not a replacement of the whole remote entity.
  final Map<String, dynamic> updates;
  final List<String> conflictingFields;
  bool get canApplyAutomatically => conflictingFields.isEmpty;
}

bool isDefaultSyncFormValue(String key, Object? value) {
  const checkboxes = {
    'apa',
    'invalidity',
    'homeHelp',
    'prepare',
    'basement',
    'rdc',
    'floor',
    'secondFloor',
    'thirdFloor',
    'garage',
    'veranda',
    'balcon',
    'terrasse',
    'jardin',
    'heatingMain',
    'voletsRoulantsManuelsEntier',
    'voletsRoulantsElectriquesEntier',
    'voletsPersiennesEntier',
    'cheminementEscalierExterieur',
    'cheminementEscalierInterieur',
    'cheminementPenteDouce',
    'cheminementPlat',
    'cheminementQuelquesMarches',
    'cheminementParArriere',
    'cheminementSeuilPorte',
    'difficultesCirculationInterieure',
  };
  const emptyValues = {
    'firstName',
    'lastName',
    'occupant2FirstName',
    'occupant2LastName',
    'email',
    'phone',
    'address',
    'city',
    'postalCode',
    'invalidityTxt',
    'homeHelpTxt',
    'dependenceTxt',
    'personneConfiance',
    'telephonePersonneConfiance',
    'mailPersonneConfiance',
    'numeroSecuriteSocialeMonsieur',
    'numeroSecuriteSocialeMadame',
    'compteAnah',
    'natureAccompagnement',
    'envoiRapport',
    'personnesPresentesVisite',
    'yearConstruction',
    'yearHabitation',
    'surface',
    'basementDesc',
    'rdcDesc',
    'floorDesc',
    'voletsRoulantsManuelsLocalisation',
    'voletsRoulantsElectriquesLocalisation',
    'voletsPersiennesLocalisation',
    'comments',
    'accessObservation',
    'observations',
    'observationEquipements',
    'projetSouhaitUsage',
    'resumePreconisations',
    'observationEquipementsUtilisation',
    'easyAccess',
    'porteSdbLargeurSuffisante',
    'porteSdbSensAdapte',
    'porteWcLargeurSuffisante',
    'porteWcSensAdapte',
  };
  final empty = value == null || (value is String && value.trim().isEmpty);
  if (checkboxes.contains(key)) {
    return empty ||
        value == false ||
        value == 'false' ||
        value == 0 ||
        value == '0';
  }
  return emptyValues.contains(key) && empty;
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
    } else if (equivalentSyncField(key, remoteValues[key], entry.value)) {
      // Already applied (e.g. a successful request whose response was lost).
      continue;
    } else if (baseValues.containsKey(key) &&
        equivalentSyncField(key, baseValues[key], remoteValues[key])) {
      // A deliberate edit of the current value also permits clearing it.
      patch[key] = entry.value;
    } else if (isDefaultSyncFormValue(key, remoteValues[key]) &&
        !isDefaultSyncFormValue(key, entry.value)) {
      patch[key] = entry.value;
    } else if (isDefaultSyncFormValue(key, entry.value) &&
        !isDefaultSyncFormValue(key, remoteValues[key])) {
      // Retain the entered server value and let selective reconciliation
      // restore it locally instead of sending a default back to the server.
      continue;
    } else if (!baseValues.containsKey(key)) {
      conflicts.add(key);
    } else if (equivalentSyncField(key, baseValues[key], entry.value)) {
      // The local edit was undone; retain the remote change.
      continue;
    } else {
      conflicts.add(key);
    }
  }
  return SyncMergePlan(updates: patch, conflictingFields: conflicts);
}

/// Only content conflicts with an original baseline can resume automatically.
/// Malformed values, missing records and authorization failures stay visible.
bool canAutomaticallyResumeConflict(Map<String, dynamic> payload) {
  final conflict = payload['conflict'];
  final guard = payload['concurrency'];
  if (conflict is! Map ||
      guard is! Map ||
      guard['version'] != 1 ||
      guard['baseValues'] is! Map ||
      payload['updates'] is! Map) {
    return false;
  }
  final remote = conflict['remote'];
  final code = (remote is Map ? remote['error'] : null) ?? conflict['code'];
  // A legacy false reference may actually mean unanswered. A newer null
  // could be an intentional web clear; only the server's unchanged-version
  // repair may authorize automatically retrying this ambiguous reference.
  final updates = payload['updates'] as Map;
  final base = guard['baseValues'] as Map;
  final conflicting = remote is Map ? remote['conflictFields'] : null;
  if (base['easyAccess'] == false &&
      updates['easyAccess'] is bool &&
      conflicting is List &&
      conflicting.contains('acces_facile_rue')) {
    final expected = guard['expectedUpdatedAt'] is String
        ? DateTime.tryParse(guard['expectedUpdatedAt'])
        : null;
    final current = remote is Map && remote['remoteUpdatedAt'] is String
        ? DateTime.tryParse(remote['remoteUpdatedAt'])
        : null;
    if (expected == null ||
        current == null ||
        !expected.isAtSameMomentAs(current)) {
      return false;
    }
  }

  if (guard['writeId'] is! String ||
      !(payload['updates'] as Map).keys.every(
        (guard['baseValues'] as Map).containsKey,
      )) {
    return false;
  }
  return const {
    'SYNC_FIELD_CONFLICT',
    'SYNC_REMOTE_VALUES_REQUIRE_REVIEW',
    'LOCAL_EDIT_BASE_CHANGED',
  }.contains(code);
}

/// Merge only properties edited since the captured baseline. A full occupant
/// serialization must not erase an independent server change to health/admin.
Map<String, dynamic> mergeLatestPatientValues({
  required Map<String, dynamic> local,
  required Map<String, dynamic> remote,
  required Map<String, dynamic> baseline,
}) {
  final merged = <String, dynamic>{};
  for (final entry in local.entries) {
    final key = entry.key;
    if (key != 'occupants') {
      final plan = planSyncMerge(
        baseValues: baseline,
        updates: {key: entry.value},
        remoteValues: remote,
      );
      if (!plan.canApplyAutomatically) {
        throw StateError(
          'Deux versions différentes de cette information existent.',
        );
      }
      merged[key] = plan.updates.containsKey(key)
          ? plan.updates[key]
          : remote[key];
      continue;
    }
    final before = canonicalOccupantValues(baseline[key]);
    final after = canonicalOccupantValues(entry.value);
    final current = canonicalOccupantValues(remote[key]);
    if (before is! List ||
        after is! List ||
        current is! List ||
        before.length != after.length ||
        before.length != current.length) {
      throw StateError('La composition du foyer a changé.');
    }
    final people = <Map<String, dynamic>>[];
    for (var i = 0; i < before.length; i++) {
      final b = before[i], a = after[i], r = current[i];
      if (b is! Map || a is! Map || r is! Map) {
        throw StateError('Occupant invalide.');
      }
      for (final identity in ['firstName', 'lastName', 'birthDate']) {
        if (!equivalentSyncField(
          identity,
          b[identity] ?? '',
          r[identity] ?? '',
        )) {
          throw StateError('L’identité des occupants a changé.');
        }
      }
      final plan = planSyncMerge(
        baseValues: b.cast<String, dynamic>(),
        updates: a.cast<String, dynamic>(),
        remoteValues: r.cast<String, dynamic>(),
      );
      if (!plan.canApplyAutomatically) {
        throw StateError(
          'Deux versions différentes des informations du foyer existent.',
        );
      }
      people.add({...r.cast<String, dynamic>(), ...plan.updates});
    }
    merged[key] = people;
  }
  return merged;
}
