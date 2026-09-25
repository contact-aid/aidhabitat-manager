import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'offline_vault.dart';
import 'visit_recommendations_publication.dart';

typedef VisitRecommendationsPayloadTransform =
    Future<String> Function(String value);

String _newWriteId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

class VisitRecommendationsWikiRemapCommit {
  const VisitRecommendationsWikiRemapCommit({
    required this.rowsChanged,
    required this.operationsChanged,
    required this.operationsCreated,
    required this.requiresManualResolution,
  });

  final int rowsChanged;
  final int operationsChanged;
  final int operationsCreated;
  final bool requiresManualResolution;

  bool get changed => rowsChanged > 0 || operationsChanged > 0;
  bool get shouldNotifySync => operationsChanged > 0 || operationsCreated > 0;
}

Map<String, dynamic> _decodeObject(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! Map) throw const FormatException('Expected a JSON object');
  return decoded.cast<String, dynamic>();
}

List<Map<String, dynamic>> _decodeItems(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) throw const FormatException('Expected a JSON list');
  return decoded
      .map((item) {
        if (item is! Map) {
          throw const FormatException('Expected recommendation objects');
        }
        return item.cast<String, dynamic>();
      })
      .toList(growable: false);
}

List<Map<String, dynamic>> _publishableItems(List<Map<String, dynamic>> items) {
  return items
      .where((item) {
        final id = (item['wikiItemId']?.toString() ?? '').trim().toLowerCase();
        return id.isNotEmpty && !id.startsWith('local_draft_');
      })
      .toList(growable: false);
}

bool _remapItemsAtKey(
  Map<String, dynamic> container,
  String key,
  String oldWikiItemId,
  String newWikiItemId,
) {
  final rawItems = container[key];
  if (rawItems is! List) return false;
  final items = rawItems
      .map((item) {
        if (item is! Map) return item;
        final copy = Map<String, dynamic>.from(item.cast<String, dynamic>());
        if ((copy['wikiItemId']?.toString() ?? '').trim() == oldWikiItemId) {
          copy['wikiItemId'] = newWikiItemId;
        }
        return copy;
      })
      .toList(growable: false);
  final changed = jsonEncode(items) != jsonEncode(rawItems);
  if (changed) container[key] = items;
  return changed;
}

bool _remapQueuedPayload(
  Map<String, dynamic> payload,
  String oldWikiItemId,
  String newWikiItemId,
) {
  var changed = _remapItemsAtKey(
    payload,
    'items',
    oldWikiItemId,
    newWikiItemId,
  );
  for (final key in const ['updates', 'envelope']) {
    final nested = payload[key];
    if (nested is Map) {
      changed =
          _remapItemsAtKey(
            nested.cast<String, dynamic>(),
            'items',
            oldWikiItemId,
            newWikiItemId,
          ) ||
          changed;
    }
  }
  return changed;
}

void _validateVersionedReference(Map<String, dynamic> payload) {
  final nested = payload['envelope'];
  final envelope = nested is Map
      ? nested.cast<String, dynamic>()
      : payload.containsKey('protocolVersion')
      ? payload
      : null;
  if (envelope != null &&
      envelope.containsKey('protocolVersion') &&
      !envelope.containsKey('expectedRevision')) {
    throw StateError(
      'A versioned recommendation envelope has no expectedRevision',
    );
  }
}

void _renewWriteIds(Map<String, dynamic> payload, String writeId) {
  if (payload.containsKey('writeId')) payload['writeId'] = writeId;
  final envelope = payload['envelope'];
  if (envelope is Map && envelope.containsKey('writeId')) {
    envelope['writeId'] = writeId;
  }
  for (final key in const ['concurrency', 'localReference']) {
    final guard = payload[key];
    if (guard is Map && guard.containsKey('writeId')) {
      guard['writeId'] = writeId;
    }
  }
}

bool _payloadReferences(Map<String, dynamic> payload, String wikiItemId) {
  bool itemsReference(Object? value) =>
      value is List &&
      value.any((item) {
        return item is Map &&
            (item['wikiItemId']?.toString() ?? '').trim() == wikiItemId;
      });

  if (itemsReference(payload['items'])) return true;
  for (final key in const ['updates', 'envelope']) {
    final nested = payload[key];
    if (nested is Map && itemsReference(nested['items'])) return true;
  }
  return false;
}

Map<String, dynamic> _legacyPublicationPayload({
  required String dossierId,
  required List<Map<String, dynamic>> items,
  required String writeId,
}) {
  return <String, dynamic>{
    'dossierId': dossierId,
    'updates': <String, dynamic>{'items': items},
    'items': items,
    'mutationOrigin': SyncMutationOrigin.dataMigration.wireName,
    'localReference': <String, dynamic>{
      'version': 1,
      'writeId': writeId,
      'baseValues': <String, dynamic>{},
      'expectedUpdatedAt': null,
    },
  };
}

/// Commits a wiki-id acknowledgement into recommendation rows and their queue.
///
/// This function must be called inside the same SQLite transaction as the wiki
/// acknowledgement. It never starts or commits a transaction itself. A caller
/// may notify the sync engine only after the outer transaction has committed.
Future<VisitRecommendationsWikiRemapCommit>
remapVisitRecommendationReferencesInTransaction(
  DatabaseExecutor txn,
  String oldWikiItemId,
  String newWikiItemId, {
  VisitRecommendationsPayloadTransform? openPayload,
  VisitRecommendationsPayloadTransform? sealPayload,
  String Function()? createWriteId,
  DateTime Function()? clock,
}) async {
  final oldId = oldWikiItemId.trim();
  final newId = newWikiItemId.trim();
  if (oldId.isEmpty ||
      !oldId.toLowerCase().startsWith('local_draft_') ||
      newId.isEmpty ||
      newId.toLowerCase().startsWith('local_draft_')) {
    throw ArgumentError('Expected a local_draft_ source and a final wiki id');
  }

  final decodePayload = openPayload ?? OfflineVault.instance.openString;
  final encodePayload = sealPayload ?? OfflineVault.instance.sealString;
  final nextWriteId = createWriteId ?? _newWriteId;
  final now = (clock ?? DateTime.now)().toIso8601String();

  final recommendationRows = await txn.query('visit_recommendations');
  final operationRows = await txn.query(
    'sync_operations',
    where: 'entity_type = ? AND status != ?',
    whereArgs: const ['visit_recommendations', 'completed'],
  );

  final decodedOperations = <Map<String, dynamic>, Map<String, dynamic>>{};
  for (final row in operationRows) {
    final payload = _decodeObject(
      await decodePayload(row['payload_json'] as String),
    );
    _validateVersionedReference(payload);
    decodedOperations[row] = payload;
    if (row['status'] == 'running' && _payloadReferences(payload, oldId)) {
      throw StateError(
        'A running recommendation publication contains a local wiki id',
      );
    }
  }

  var rowsChanged = 0;
  var operationsChanged = 0;
  var operationsCreated = 0;
  var requiresManualResolution = false;

  for (final row in recommendationRows) {
    final items = _decodeItems(row['items_json'] as String);
    final remap = remapVisitRecommendationWikiReference(
      items: items,
      oldWikiItemId: oldId,
      newWikiItemId: newId,
    );
    if (!remap.changed) continue;

    final dossierId = row['dossier_local_id']?.toString() ?? '';
    final dossierOperations = decodedOperations.entries
        .where((entry) => entry.key['entity_local_id'] == dossierId)
        .toList(growable: false);
    final statuses = dossierOperations
        .map((entry) => entry.key['status']?.toString())
        .toSet();
    final syncState = statuses.contains('conflict')
        ? 'conflict'
        : statuses.contains('failed')
        ? 'syncError'
        : 'pendingSync';

    rowsChanged += await txn.update(
      'visit_recommendations',
      {
        'items_json': jsonEncode(remap.items),
        'updated_at': now,
        'sync_state': syncState,
      },
      where: 'local_id = ?',
      whereArgs: [row['local_id']],
    );
    var hasDurableFollowUp = false;

    for (final entry in dossierOperations) {
      final operation = entry.key;
      final status = operation['status']?.toString() ?? '';
      if (status == 'running') continue;

      final payload = entry.value;
      final payloadChanged = _remapQueuedPayload(payload, oldId, newId);
      if (status == 'pending') {
        final published = _publishableItems(remap.items);
        payload['items'] = published;
        final updates = payload['updates'];
        if (updates is Map) updates['items'] = published;
        final envelope = payload['envelope'];
        if (envelope is Map) envelope['items'] = published;
      }
      if (payloadChanged || status == 'pending') {
        _renewWriteIds(payload, nextWriteId());
        operationsChanged += await txn.update(
          'sync_operations',
          {
            'payload_json': await encodePayload(jsonEncode(payload)),
            'updated_at': now,
          },
          where: 'id = ? AND status = ?',
          whereArgs: [operation['id'], status],
        );
      }
      if (status == 'pending') hasDurableFollowUp = true;
      if (status == 'failed' || status == 'conflict') {
        hasDurableFollowUp = true;
        requiresManualResolution = true;
      }
    }

    if (!hasDurableFollowUp) {
      final writeId = nextWriteId();
      final payload = _legacyPublicationPayload(
        dossierId: dossierId,
        items: _publishableItems(remap.items),
        writeId: writeId,
      );
      await txn.insert('sync_operations', {
        'id': 'visitrec_update_${dossierId}_wiki_$writeId',
        'entity_type': 'visit_recommendations',
        'entity_local_id': dossierId,
        'operation_type': 'update',
        'payload_json': await encodePayload(jsonEncode(payload)),
        'status': 'pending',
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
      operationsCreated += 1;
    }
  }

  return VisitRecommendationsWikiRemapCommit(
    rowsChanged: rowsChanged,
    operationsChanged: operationsChanged,
    operationsCreated: operationsCreated,
    requiresManualResolution: requiresManualResolution,
  );
}
