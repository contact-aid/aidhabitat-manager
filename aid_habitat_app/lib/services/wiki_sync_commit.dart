import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'offline_vault.dart';

/// Applies and acknowledges exactly one HTTP response. The caller must NOT
/// subsequently use the generic markCompleted path for this operation.
Future<bool> commitWikiSyncResponse({
  required Database database,
  required SyncOperation operation,
  required Future<void> Function(Transaction txn, String oldId, String newId)
  remapReferences,
  WikiItem? saved,
  void Function()? validateSession,
}) async {
  if (operation.entityType != 'wiki_item' ||
      !const ['create', 'update', 'delete'].contains(operation.operationType)) {
    throw ArgumentError('Expected a wiki mutation');
  }
  if (operation.operationType != 'delete' &&
      (saved == null || saved.id.isEmpty)) {
    throw ArgumentError('Missing saved wiki identity');
  }
  return database.transaction((txn) async {
    validateSession?.call();
    final claims = await txn.query(
      'sync_operations',
      where:
          'id = ? AND entity_type = ? AND entity_local_id = ? '
          'AND operation_type = ? AND status = ?',
      whereArgs: [
        operation.id,
        'wiki_item',
        operation.entityLocalId,
        operation.operationType,
        'running',
      ],
    );
    if (claims.length != 1 ||
        await OfflineVault.instance.openString(
              claims.single['payload_json'] as String,
            ) !=
            operation.payloadJson) {
      return false;
    }

    final localId = operation.entityLocalId;
    final targetId = operation.operationType == 'create' ? saved!.id : localId;
    if (saved != null &&
        operation.operationType == 'update' &&
        saved.id != localId) {
      throw StateError('Wiki response identity mismatch');
    }
    final rows = await txn.query(
      'wiki_items',
      where: 'id = ?',
      whereArgs: [localId],
    );
    if (rows.length != 1) {
      throw StateError('Wiki row missing; response not acknowledged');
    }
    final row = rows.single;
    final following = await txn.query(
      'sync_operations',
      where:
          'entity_type = ? AND entity_local_id = ? AND id != ? '
          'AND status != ?',
      whereArgs: ['wiki_item', localId, operation.id, 'completed'],
    );
    final now = DateTime.now().toIso8601String();

    if (operation.operationType == 'delete') {
      if (following.isNotEmpty || row['pending_delete'] != 1) {
        throw StateError('Wiki deletion no longer owns the local row');
      }
      await txn.delete('wiki_items', where: 'id = ?', whereArgs: [localId]);
    } else {
      if (targetId != localId) {
        final collisions = await txn.query(
          'wiki_items',
          columns: ['id'],
          where: 'id = ?',
          whereArgs: [targetId],
        );
        if (collisions.isNotEmpty) {
          throw StateError('Remote wiki identity already exists locally');
        }
        // Keep the latest row, including pending image and deletion tombstone.
        await txn.update(
          'wiki_items',
          {'id': targetId},
          where: 'id = ?',
          whereArgs: [localId],
        );
        // The recommendations owner remaps local references and replans its
        // unpublished intents here, using the SAME transaction. Never mutate
        // the content/writeId of an already running publication.
        await remapReferences(txn, localId, targetId);
        for (final next in following) {
          if (next['status'] == 'running') {
            throw StateError('Concurrent wiki worker during identity remap');
          }
          final payload =
              jsonDecode(
                    await OfflineVault.instance.openString(
                      next['payload_json'] as String,
                    ),
                  )
                  as Map<String, dynamic>;
          payload['itemId'] = targetId;
          await txn.update(
            'sync_operations',
            {
              'entity_local_id': targetId,
              'operation_type': next['operation_type'] == 'create'
                  ? 'update'
                  : next['operation_type'],
              'payload_json': await OfflineVault.instance.sealString(
                jsonEncode(payload),
              ),
            },
            where: 'id = ?',
            whereArgs: [next['id']],
          );
        }
      }
      final states = following.map((op) => op['status']).toSet();
      final state = states.contains('conflict')
          ? SyncState.conflict
          : states.contains('failed')
          ? SyncState.syncError
          : following.isNotEmpty
          ? SyncState.pendingSync
          : SyncState.synced;
      // Any following intent owns the user-facing fields. Only an uncontested
      // response may replace them or clear the pending image.
      final values = <String, Object?>{
        'last_synced_at': now,
        'sync_state': state.name,
        if (following.isEmpty && row['pending_delete'] != 1) ...{
          'title': saved!.title,
          'description': saved.description,
          'image_url': saved.imageUrl,
          'tags_json': jsonEncode(saved.tags),
          'category': saved.category,
          'updated_at': saved.updatedAt,
          'pending_image_data_url': null,
        },
      };
      await txn.update(
        'wiki_items',
        values,
        where: 'id = ?',
        whereArgs: [targetId],
      );
    }
    validateSession?.call();
    await txn.update(
      'sync_operations',
      {'status': 'completed', 'last_error': null, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [operation.id],
    );
    return true;
  });
}
