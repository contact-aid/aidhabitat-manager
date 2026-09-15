import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'sync_operation_ownership.dart';

/// Local authorship confirmation, not a grant of server permissions.
class SyncOwnershipSelfReview {
  static Future<String?> activeUserId(DatabaseExecutor db) async {
    final rows = await db.rawQuery('''
      SELECT user.local_id FROM app_session AS session
      JOIN app_users AS user ON user.local_id = session.user_local_id
      WHERE session.id = 1 AND user.is_active = 1 LIMIT 1
    ''');
    return rows.isEmpty ? null : rows.single['local_id'] as String;
  }

  /// Must run in the same transaction as the caller's session-epoch checks.
  /// The persisted snapshot and previous metadata are retained before adoption.
  static Future<bool> confirm({
    required Transaction txn,
    required ReviewableSyncOperation expected,
    required String userId,
  }) async {
    if (await activeUserId(txn) != userId) return false;
    final rows = await txn.rawQuery(
      '''
      SELECT operation.id FROM sync_operations AS operation
      LEFT JOIN ${SyncOperationOwnership.tableName} AS ownership
        ON ownership.operation_id = operation.id
      WHERE operation.id = ? AND operation.payload_json = ?
        AND operation.updated_at = ? AND operation.status = ?
        AND operation.status NOT IN ('completed', 'running')
        AND ownership.owner_user_local_id IS ?
        AND ownership.candidate_user_local_id IS ?
        AND ownership.attribution_state IS ?
        AND (ownership.owner_user_local_id IS NULL OR ownership.owner_user_local_id = ?)
        AND (ownership.candidate_user_local_id IS NULL OR ownership.candidate_user_local_id = ?)
        AND (ownership.operation_id IS NULL OR ownership.attribution_state IN (?, ?))
    ''',
      [
        expected.operationId,
        expected.sealedPayloadJson,
        expected.updatedAt,
        expected.status,
        expected.ownerUserLocalId,
        expected.candidateUserLocalId,
        expected.attributionState,
        userId,
        userId,
        SyncOperationOwnership.historicalUnattributed,
        SyncOperationOwnership.reviewRequired,
      ],
    );
    if (rows.length != 1) return false;
    final changed = await SyncOperationOwnership.reviewAttribution(
      txn: txn,
      operationId: expected.operationId,
      expectedPayloadJson: expected.sealedPayloadJson,
      expectedPreviousOwnerUserLocalId: expected.ownerUserLocalId,
    );
    if (!changed) return false;
    // A failed history write rolls back the attribution as well.
    await txn.insert(SyncOperationOwnership.historyTableName, {
      'operation_id': expected.operationId,
      'owner_user_local_id': expected.ownerUserLocalId,
      'payload_json': expected.sealedPayloadJson,
      'operation_updated_at': expected.updatedAt,
      'reason': jsonEncode({
        'event': 'explicit_self_confirmation',
        'confirmedBy': userId,
        'previousCandidate': expected.candidateUserLocalId,
        'previousState': expected.attributionState,
      }),
      'captured_at': DateTime.now().toUtc().toIso8601String(),
    });
    return true;
  }
}
