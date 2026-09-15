import 'package:sqflite/sqflite.dart';

class SyncOperationOwnershipCounts {
  const SyncOperationOwnershipCounts({
    required this.historicalUnattributed,
    required this.reviewRequired,
    required this.ownerMismatch,
    required this.missingOwnership,
    required this.hasActiveSession,
  });

  final int historicalUnattributed;
  final int reviewRequired;
  final int ownerMismatch;
  final int missingOwnership;
  final bool hasActiveSession;

  bool get blocksDispatch =>
      !hasActiveSession ||
      historicalUnattributed > 0 ||
      reviewRequired > 0 ||
      ownerMismatch > 0 ||
      missingOwnership > 0;
}

class ReviewableSyncOperation {
  const ReviewableSyncOperation({
    required this.operationId,
    required this.entityType,
    required this.entityLocalId,
    required this.operationType,
    required this.status,
    required this.sealedPayloadJson,
    required this.ownerUserLocalId,
    required this.candidateUserLocalId,
    required this.attributionState,
    required this.updatedAt,
  });

  final String operationId;
  final String entityType;
  final String entityLocalId;
  final String operationType;
  final String status;

  /// Exact persisted value used for compare-and-set, not for logging.
  final String sealedPayloadJson;
  final String? ownerUserLocalId;
  final String? candidateUserLocalId;
  final String? attributionState;
  final String updatedAt;
}

/// Additive compatibility storage for local queue ownership.
///
/// The v24 migration preserves historical intentions without inferring an
/// author from whichever account happens to be signed in during the upgrade.
class SyncOperationOwnership {
  SyncOperationOwnership._();

  static const tableName = 'sync_operation_ownership';
  static const historicalUnattributed = 'historical_unattributed';
  static const capturedAtEnqueue = 'captured_at_enqueue';
  static const reviewRequired = 'review_required';
  static const reviewed = 'reviewed';
  static const historyTableName = 'sync_operation_ownership_history';

  /// Installs ownership metadata without attributing historical work to the
  /// session active during migration.
  ///
  /// The historical seed must run before the triggers are created. The sidecar
  /// table intentionally has no cascading foreign key: an `INSERT OR REPLACE`
  /// of a queue row must preserve its original owner record.
  static Future<void> installMigration(DatabaseExecutor db) async {
    await installSchemaAndSeed(db);
    await installTriggers(db);
  }

  /// Creates the sidecar tables and marks every pre-existing operation as
  /// unattributed. On web this must run before the initial vault sealing.
  static Future<void> installSchemaAndSeed(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $tableName (
        operation_id TEXT PRIMARY KEY,
        owner_user_local_id TEXT,
        candidate_user_local_id TEXT,
        attribution_state TEXT NOT NULL,
        created_at TEXT NOT NULL,
        reviewed_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $historyTableName (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        operation_id TEXT NOT NULL,
        owner_user_local_id TEXT,
        payload_json TEXT NOT NULL,
        operation_updated_at TEXT NOT NULL,
        reason TEXT NOT NULL,
        captured_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_operation_ownership_owner
      ON $tableName(owner_user_local_id, attribution_state)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_operation_owner_history_operation
      ON $historyTableName(operation_id, captured_at)
    ''');

    // Existing rows are ambiguous even when an app_session currently exists.
    await db.rawInsert('''
      INSERT OR IGNORE INTO $tableName (
        operation_id,
        owner_user_local_id,
        candidate_user_local_id,
        attribution_state,
        created_at,
        reviewed_at
      )
      SELECT
        id,
        NULL,
        NULL,
        '$historicalUnattributed',
        COALESCE(created_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
        NULL
      FROM sync_operations
    ''');
  }

  /// Enables mutation tracking. On web this must run only after the initial
  /// vault sealing, otherwise a technical encryption rewrite looks like a user
  /// edit and archives plaintext unnecessarily.
  static Future<void> installTriggers(DatabaseExecutor db) async {
    for (final trigger in const [
      'trg_sync_operation_owner_before_insert',
      'trg_sync_operation_owner_after_insert',
      'trg_sync_operation_owner_before_payload_update',
      'trg_sync_operation_owner_payload_update',
    ]) {
      await db.execute('DROP TRIGGER IF EXISTS $trigger');
    }

    // BEFORE INSERT can still read the row which INSERT OR REPLACE is about to
    // supersede. Archive the exact sealed payload before SQLite removes it.
    await db.execute('''
      CREATE TRIGGER trg_sync_operation_owner_before_insert
      BEFORE INSERT ON sync_operations
      BEGIN
        INSERT INTO $historyTableName (
          operation_id,
          owner_user_local_id,
          payload_json,
          operation_updated_at,
          reason,
          captured_at
        )
        SELECT
          existing.id,
          COALESCE(
            ownership.candidate_user_local_id,
            ownership.owner_user_local_id
          ),
          existing.payload_json,
          existing.updated_at,
          'cross_user_replace',
          strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        FROM sync_operations AS existing
        JOIN $tableName AS ownership
          ON ownership.operation_id = existing.id
        WHERE existing.id = NEW.id
          AND existing.status != 'completed'
          AND (
            COALESCE(
              ownership.candidate_user_local_id,
              ownership.owner_user_local_id
            ) IS NULL
            OR COALESCE(
              ownership.candidate_user_local_id,
              ownership.owner_user_local_id
            ) IS NOT (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM $historyTableName AS history
            WHERE history.operation_id = existing.id
              AND history.owner_user_local_id IS COALESCE(
                ownership.candidate_user_local_id,
                ownership.owner_user_local_id
              )
              AND history.payload_json = existing.payload_json
          );

        -- A confirmed intention must not lend its owner to the next edit.
        -- Keep unknown orphan metadata: absence alone is not confirmation.
        DELETE FROM $tableName
        WHERE operation_id = NEW.id
          AND EXISTS (
            SELECT 1 FROM sync_operations
            WHERE id = NEW.id AND status = 'completed'
          );
      END
    ''');

    await db.execute('''
      CREATE TRIGGER trg_sync_operation_owner_after_insert
      AFTER INSERT ON sync_operations
      BEGIN
        INSERT INTO $tableName (
          operation_id,
          owner_user_local_id,
          candidate_user_local_id,
          attribution_state,
          created_at,
          reviewed_at
        ) SELECT
          NEW.id,
          (SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1),
          NULL,
          CASE
            WHEN EXISTS (SELECT 1 FROM app_session WHERE id = 1)
              THEN '$capturedAtEnqueue'
            ELSE '$reviewRequired'
          END,
          COALESCE(NEW.created_at, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
          NULL
        WHERE NOT EXISTS (
          SELECT 1 FROM $tableName WHERE operation_id = NEW.id
        );

        UPDATE $tableName
        SET attribution_state = '$reviewRequired',
            candidate_user_local_id = (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            ),
            reviewed_at = NULL
        WHERE operation_id = NEW.id
          AND (
            COALESCE(candidate_user_local_id, owner_user_local_id) IS NULL
            OR COALESCE(candidate_user_local_id, owner_user_local_id) IS NOT (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            )
          );
      END
    ''');

    await db.execute('''
      CREATE TRIGGER trg_sync_operation_owner_before_payload_update
      BEFORE UPDATE OF payload_json ON sync_operations
      BEGIN
        INSERT INTO $historyTableName (
          operation_id,
          owner_user_local_id,
          payload_json,
          operation_updated_at,
          reason,
          captured_at
        )
        SELECT
          OLD.id,
          COALESCE(
            ownership.candidate_user_local_id,
            ownership.owner_user_local_id
          ),
          OLD.payload_json,
          OLD.updated_at,
          'cross_user_update',
          strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
        FROM $tableName AS ownership
        WHERE ownership.operation_id = OLD.id
          AND (
            COALESCE(
              ownership.candidate_user_local_id,
              ownership.owner_user_local_id
            ) IS NULL
            OR COALESCE(
              ownership.candidate_user_local_id,
              ownership.owner_user_local_id
            ) IS NOT (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM $historyTableName AS history
            WHERE history.operation_id = OLD.id
              AND history.owner_user_local_id IS COALESCE(
                ownership.candidate_user_local_id,
                ownership.owner_user_local_id
              )
              AND history.payload_json = OLD.payload_json
          );
      END
    ''');

    await db.execute('''
      CREATE TRIGGER trg_sync_operation_owner_payload_update
      AFTER UPDATE OF payload_json ON sync_operations
      BEGIN
        UPDATE $tableName
        SET attribution_state = '$reviewRequired',
            candidate_user_local_id = (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            ),
            reviewed_at = NULL
        WHERE operation_id = NEW.id
          AND (
            COALESCE(candidate_user_local_id, owner_user_local_id) IS NULL
            OR COALESCE(candidate_user_local_id, owner_user_local_id) IS NOT (
              SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
            )
          );
      END
    ''');
  }

  /// Returns true only for a pending operation durably owned by the active
  /// local user. Server authorization remains mandatory.
  static Future<bool> mayClaim(DatabaseExecutor txn, String operationId) async {
    final rows = await txn.rawQuery(
      '''
      SELECT 1
      FROM sync_operations AS operation
      JOIN $tableName AS ownership
        ON ownership.operation_id = operation.id
      JOIN app_session AS session
        ON session.id = 1
       AND session.user_local_id = ownership.owner_user_local_id
      WHERE operation.id = ?
        AND operation.status = 'pending'
        AND ownership.attribution_state IN (?, ?)
      LIMIT 1
    ''',
      [operationId, capturedAtEnqueue, reviewed],
    );
    return rows.isNotEmpty;
  }

  /// Explicitly attributes a reviewed operation to the active local user.
  ///
  /// Both the payload and previous owner are compare-and-set inputs. If the
  /// operation changed while the review UI was open, no attribution occurs.
  /// [expectedPayloadJson] is the exact persisted value, including vault
  /// sealing when applicable; it must not be reconstructed from decoded data.
  static Future<bool> reviewAttribution({
    required DatabaseExecutor txn,
    required String operationId,
    required String expectedPayloadJson,
    required String? expectedPreviousOwnerUserLocalId,
    DateTime? reviewedAt,
  }) async {
    final timestamp = (reviewedAt ?? DateTime.now()).toUtc().toIso8601String();
    // Repair absent metadata only within the explicit review transaction.
    // The payload check prevents adopting an edit made after the review opened.
    if (expectedPreviousOwnerUserLocalId == null) {
      await txn.rawInsert(
        '''INSERT OR IGNORE INTO $tableName (
             operation_id, owner_user_local_id, candidate_user_local_id,
             attribution_state, created_at, reviewed_at
           )
           SELECT id, NULL, NULL, '$historicalUnattributed', created_at, NULL
           FROM sync_operations
           WHERE id = ? AND payload_json = ?
             AND status NOT IN ('completed', 'running')
             AND EXISTS (SELECT 1 FROM app_session WHERE id = 1)''',
        [operationId, expectedPayloadJson],
      );
    }
    final changed = await txn.rawUpdate(
      '''
      UPDATE $tableName
      SET owner_user_local_id = (
            SELECT user_local_id FROM app_session WHERE id = 1 LIMIT 1
          ),
          candidate_user_local_id = NULL,
          attribution_state = '$reviewed',
          reviewed_at = ?
      WHERE operation_id = ?
        AND owner_user_local_id IS ?
        AND EXISTS (SELECT 1 FROM app_session WHERE id = 1)
        AND EXISTS (
          SELECT 1
          FROM sync_operations AS operation
          WHERE operation.id = $tableName.operation_id
            AND operation.payload_json = ?
            AND operation.status NOT IN ('completed', 'running')
        )
    ''',
      [
        timestamp,
        operationId,
        expectedPreviousOwnerUserLocalId,
        expectedPayloadJson,
      ],
    );
    return changed == 1;
  }

  static Future<SyncOperationOwnershipCounts> blockedCounts(
    DatabaseExecutor db,
  ) async {
    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE
          WHEN ownership.attribution_state = '$historicalUnattributed'
            THEN 1 ELSE 0 END) AS historical_unattributed,
        SUM(CASE
          WHEN ownership.attribution_state = '$reviewRequired'
            THEN 1 ELSE 0 END) AS review_required,
        SUM(CASE
          WHEN session.user_local_id IS NOT NULL
           AND ownership.owner_user_local_id IS NOT NULL
           AND ownership.owner_user_local_id != session.user_local_id
            THEN 1 ELSE 0 END) AS owner_mismatch,
        SUM(CASE
          WHEN ownership.operation_id IS NULL THEN 1 ELSE 0 END
        ) AS missing_ownership,
        (SELECT CASE WHEN EXISTS (
          SELECT 1 FROM app_session WHERE id = 1
        ) THEN 1 ELSE 0 END) AS has_active_session
      FROM sync_operations AS operation
      LEFT JOIN $tableName AS ownership
        ON ownership.operation_id = operation.id
      LEFT JOIN app_session AS session
        ON session.id = 1
      WHERE operation.status != 'completed'
    ''');
    final row = rows.single;
    return SyncOperationOwnershipCounts(
      historicalUnattributed: _asInt(row['historical_unattributed']),
      reviewRequired: _asInt(row['review_required']),
      ownerMismatch: _asInt(row['owner_mismatch']),
      missingOwnership: _asInt(row['missing_ownership']),
      hasActiveSession: _asInt(row['has_active_session']) == 1,
    );
  }

  /// Lists only operations requiring an explicit attribution decision.
  ///
  /// The raw persisted payload is returned solely as an opaque CAS value for
  /// [reviewAttribution]. Callers must not log or display it. Payloads can be
  /// large, so callers must page explicitly instead of loading the full queue.
  static Future<List<ReviewableSyncOperation>> listReviewableOperations(
    DatabaseExecutor db, {
    int limit = 1,
    int offset = 0,
    String? selfReviewUserId,
  }) async {
    if (limit < 1 || limit > 20 || offset < 0) {
      throw ArgumentError(
        'Review pagination must use limit 1..20 and offset >= 0.',
      );
    }
    final rows = await db.rawQuery(
      '''
      SELECT
        operation.id AS operation_id,
        operation.entity_type,
        operation.entity_local_id,
        operation.operation_type,
        operation.status,
        operation.payload_json,
        operation.updated_at,
        ownership.owner_user_local_id,
        ownership.candidate_user_local_id,
        ownership.attribution_state
      FROM sync_operations AS operation
      LEFT JOIN $tableName AS ownership
        ON ownership.operation_id = operation.id
      WHERE operation.status != 'completed'
        AND (? IS NULL OR (
          (ownership.owner_user_local_id IS NULL OR ownership.owner_user_local_id = ?)
          AND (ownership.candidate_user_local_id IS NULL OR ownership.candidate_user_local_id = ?)
        ))
        AND (
          ownership.operation_id IS NULL
          OR ownership.attribution_state IN (?, ?)
      )
      ORDER BY operation.created_at ASC, operation.id ASC
      LIMIT ? OFFSET ?
    ''',
      [
        selfReviewUserId,
        selfReviewUserId,
        selfReviewUserId,
        historicalUnattributed,
        reviewRequired,
        limit,
        offset,
      ],
    );
    return rows
        .map(
          (row) => ReviewableSyncOperation(
            operationId: row['operation_id'] as String,
            entityType: row['entity_type'] as String,
            entityLocalId: row['entity_local_id'] as String,
            operationType: row['operation_type'] as String,
            status: row['status'] as String,
            sealedPayloadJson: row['payload_json'] as String,
            ownerUserLocalId: row['owner_user_local_id'] as String?,
            candidateUserLocalId: row['candidate_user_local_id'] as String?,
            attributionState: row['attribution_state'] as String?,
            updatedAt: row['updated_at'] as String,
          ),
        )
        .toList(growable: false);
  }

  static int _asInt(Object? value) => value is int ? value : 0;
}
