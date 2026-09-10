import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE app_session (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        user_local_id TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_operations (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_local_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
  });

  tearDown(() => db.close());

  Future<void> setUser(String? userId) async {
    await db.delete('app_session');
    if (userId != null) {
      await db.insert('app_session', {'id': 1, 'user_local_id': userId});
    }
  }

  Future<void> insertOperation(
    String id,
    String payload, {
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.abort,
  }) {
    return db
        .insert('sync_operations', {
          'id': id,
          'entity_type': 'dossier',
          'entity_local_id': 'local-dossier',
          'operation_type': 'update',
          'payload_json': payload,
          'status': 'pending',
          'attempt_count': 0,
          'last_error': null,
          'created_at': '2026-09-10T08:00:00.000Z',
          'updated_at': '2026-09-10T08:00:00.000Z',
        }, conflictAlgorithm: conflictAlgorithm)
        .then((_) {});
  }

  test('migration never gives historical work to a current user', () async {
    await insertOperation('old', 'sealed:old');
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');

    final owner = (await db.query(
      SyncOperationOwnership.tableName,
      where: 'operation_id = ?',
      whereArgs: ['old'],
    )).single;
    expect(owner['owner_user_local_id'], isNull);
    expect(
      owner['attribution_state'],
      SyncOperationOwnership.historicalUnattributed,
    );
    expect(await SyncOperationOwnership.mayClaim(db, 'old'), isFalse);
  });

  test('production repository filters and rechecks the active owner', () async {
    await SyncOperationOwnership.installMigration(db);
    final queue = SyncRepository(databaseProvider: () async => db);
    await setUser('user-a');
    await insertOperation('owned-a', '{"updates":{"status":"EN_COURS"}}');
    final snapshot = (await queue.fetchRunnableOperations()).single;
    await setUser('user-b');
    expect(await queue.fetchRunnableOperations(), isEmpty);
    expect(await queue.tryMarkRunning(snapshot), isFalse);
    expect(
      (await queue.fetchTopFailingOperation())!['entityType'],
      'sync_ownership',
    );
    await setUser('user-a');
    expect(await queue.tryMarkRunning(snapshot), isTrue);
  });

  test('historical work stays visible but cannot be dispatched', () async {
    await insertOperation('historical', '{}');
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');
    final queue = SyncRepository(databaseProvider: () async => db);
    expect(await queue.fetchRunnableOperations(), isEmpty);
    expect(
      (await queue.fetchTopFailingOperation())!['lastError'],
      contains('vérification'),
    );
    expect((await db.query('sync_operations')).single['status'], 'pending');
  });

  test(
    'web vault rewrite can run before triggers without false review',
    () async {
      await insertOperation('legacy-web', 'plaintext:legacy');
      await SyncOperationOwnership.installSchemaAndSeed(db);
      await setUser('user-a');

      await db.update(
        'sync_operations',
        {'payload_json': 'sealed:legacy'},
        where: 'id = ?',
        whereArgs: ['legacy-web'],
      );
      await SyncOperationOwnership.installTriggers(db);

      final owner = (await db.query(
        SyncOperationOwnership.tableName,
        where: 'operation_id = ?',
        whereArgs: ['legacy-web'],
      )).single;
      expect(owner['owner_user_local_id'], isNull);
      expect(
        owner['attribution_state'],
        SyncOperationOwnership.historicalUnattributed,
      );
      expect(await db.query(SyncOperationOwnership.historyTableName), isEmpty);
    },
  );

  test('new operation captures the active owner and is claimable', () async {
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');
    await insertOperation('new-a', 'sealed:a');

    final owner = (await db.query(
      SyncOperationOwnership.tableName,
      where: 'operation_id = ?',
      whereArgs: ['new-a'],
    )).single;
    expect(owner['owner_user_local_id'], 'user-a');
    expect(
      owner['attribution_state'],
      SyncOperationOwnership.capturedAtEnqueue,
    );
    expect(await SyncOperationOwnership.mayClaim(db, 'new-a'), isTrue);
  });

  test('INSERT OR REPLACE by another user preserves both payloads', () async {
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');
    await insertOperation('shared', 'sealed:a');

    await setUser('user-b');
    await insertOperation(
      'shared',
      'sealed:b',
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final operation = (await db.query(
      'sync_operations',
      where: 'id = ?',
      whereArgs: ['shared'],
    )).single;
    final owner = (await db.query(
      SyncOperationOwnership.tableName,
      where: 'operation_id = ?',
      whereArgs: ['shared'],
    )).single;
    final history = await db.query(
      SyncOperationOwnership.historyTableName,
      where: 'operation_id = ?',
      whereArgs: ['shared'],
    );

    expect(operation['payload_json'], 'sealed:b');
    expect(owner['owner_user_local_id'], 'user-a');
    expect(owner['candidate_user_local_id'], 'user-b');
    expect(owner['attribution_state'], SyncOperationOwnership.reviewRequired);
    expect(history, hasLength(1));
    expect(history.single['owner_user_local_id'], 'user-a');
    expect(history.single['payload_json'], 'sealed:a');
    expect(await SyncOperationOwnership.mayClaim(db, 'shared'), isFalse);
  });

  test(
    'replacement also archives an unattributed historical payload',
    () async {
      await insertOperation('historical', 'sealed:unknown-a');
      await SyncOperationOwnership.installMigration(db);
      await setUser('user-b');
      await insertOperation(
        'historical',
        'sealed:b',
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final owner = (await db.query(
        SyncOperationOwnership.tableName,
        where: 'operation_id = ?',
        whereArgs: ['historical'],
      )).single;
      final history = (await db.query(
        SyncOperationOwnership.historyTableName,
        where: 'operation_id = ?',
        whereArgs: ['historical'],
      )).single;
      expect(owner['owner_user_local_id'], isNull);
      expect(owner['candidate_user_local_id'], 'user-b');
      expect(owner['attribution_state'], SyncOperationOwnership.reviewRequired);
      expect(history['owner_user_local_id'], isNull);
      expect(history['payload_json'], 'sealed:unknown-a');
      expect(await SyncOperationOwnership.mayClaim(db, 'historical'), isFalse);
    },
  );

  test(
    'cross-user UPDATE archives the prior payload and blocks claim',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await setUser('user-a');
      await insertOperation('updated', 'sealed:a');

      await setUser('user-b');
      await db.update(
        'sync_operations',
        {'payload_json': 'sealed:b'},
        where: 'id = ?',
        whereArgs: ['updated'],
      );

      final owner = (await db.query(
        SyncOperationOwnership.tableName,
        where: 'operation_id = ?',
        whereArgs: ['updated'],
      )).single;
      final history = await db.query(
        SyncOperationOwnership.historyTableName,
        where: 'operation_id = ?',
        whereArgs: ['updated'],
      );
      expect(owner['owner_user_local_id'], 'user-a');
      expect(owner['candidate_user_local_id'], 'user-b');
      expect(owner['attribution_state'], SyncOperationOwnership.reviewRequired);
      expect(history.single['payload_json'], 'sealed:a');
      expect(await SyncOperationOwnership.mayClaim(db, 'updated'), isFalse);
    },
  );

  test(
    'successive users preserve each payload with its effective author',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await setUser('user-a');
      await insertOperation('successive', 'sealed:a');
      await setUser('user-b');
      await insertOperation(
        'successive',
        'sealed:b',
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await setUser('user-c');
      await insertOperation(
        'successive',
        'sealed:c',
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final history = await db.query(
        SyncOperationOwnership.historyTableName,
        where: 'operation_id = ?',
        whereArgs: ['successive'],
        orderBy: 'id',
      );
      expect(history.map((row) => row['owner_user_local_id']), [
        'user-a',
        'user-b',
      ]);
      expect(history.map((row) => row['payload_json']), [
        'sealed:a',
        'sealed:b',
      ]);
      expect(
        (await db.query(
          'sync_operations',
          where: 'id = ?',
          whereArgs: ['successive'],
        )).single['payload_json'],
        'sealed:c',
      );
    },
  );

  test('explicit review uses payload and previous-owner CAS', () async {
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');
    await insertOperation('review', 'sealed:a');
    await setUser('user-b');
    await insertOperation(
      'review',
      'sealed:b',
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    final stale = await SyncOperationOwnership.reviewAttribution(
      txn: db,
      operationId: 'review',
      expectedPayloadJson: 'sealed:a',
      expectedPreviousOwnerUserLocalId: 'user-a',
      reviewedAt: DateTime.utc(2026, 9, 10, 9),
    );
    expect(stale, isFalse);

    final accepted = await SyncOperationOwnership.reviewAttribution(
      txn: db,
      operationId: 'review',
      expectedPayloadJson: 'sealed:b',
      expectedPreviousOwnerUserLocalId: 'user-a',
      reviewedAt: DateTime.utc(2026, 9, 10, 9),
    );
    expect(accepted, isTrue);

    final owner = (await db.query(
      SyncOperationOwnership.tableName,
      where: 'operation_id = ?',
      whereArgs: ['review'],
    )).single;
    expect(owner['owner_user_local_id'], 'user-b');
    expect(owner['candidate_user_local_id'], isNull);
    expect(owner['attribution_state'], SyncOperationOwnership.reviewed);
    expect(await SyncOperationOwnership.mayClaim(db, 'review'), isTrue);
    expect(
      await db.query(
        SyncOperationOwnership.historyTableName,
        where: 'operation_id = ?',
        whereArgs: ['review'],
      ),
      hasLength(1),
    );
  });

  test('explicit review cannot steal a running operation', () async {
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');
    await insertOperation('running', 'sealed:a');
    await db.update(
      'sync_operations',
      {'status': 'running'},
      where: 'id = ?',
      whereArgs: ['running'],
    );

    expect(
      await SyncOperationOwnership.reviewAttribution(
        txn: db,
        operationId: 'running',
        expectedPayloadJson: 'sealed:a',
        expectedPreviousOwnerUserLocalId: 'user-a',
      ),
      isFalse,
    );
  });

  test('review list and CAS never attribute operations in bulk', () async {
    await insertOperation('old-a', 'sealed:old-a');
    await insertOperation('old-b', 'sealed:old-b');
    await SyncOperationOwnership.installMigration(db);
    await setUser('user-a');

    final reviewable = await SyncOperationOwnership.listReviewableOperations(
      db,
      limit: 10,
    );
    expect(reviewable.map((item) => item.operationId), ['old-a', 'old-b']);
    expect(reviewable.first.sealedPayloadJson, 'sealed:old-a');

    expect(
      await SyncOperationOwnership.reviewAttribution(
        txn: db,
        operationId: reviewable.first.operationId,
        expectedPayloadJson: reviewable.first.sealedPayloadJson,
        expectedPreviousOwnerUserLocalId: reviewable.first.ownerUserLocalId,
      ),
      isTrue,
    );

    final owners = await db.query(
      SyncOperationOwnership.tableName,
      orderBy: 'operation_id',
    );
    expect(owners.first['owner_user_local_id'], 'user-a');
    expect(owners.first['attribution_state'], SyncOperationOwnership.reviewed);
    expect(owners.last['owner_user_local_id'], isNull);
    expect(
      owners.last['attribution_state'],
      SyncOperationOwnership.historicalUnattributed,
    );
  });

  test(
    'blocked counts expose unknown, review and active-user mismatch',
    () async {
      await insertOperation('historical', 'sealed:old');
      await SyncOperationOwnership.installMigration(db);
      await setUser('user-a');
      await insertOperation('owned-a', 'sealed:a');
      await setUser('user-b');
      await insertOperation(
        'owned-a',
        'sealed:b',
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      final counts = await SyncOperationOwnership.blockedCounts(db);
      expect(counts.hasActiveSession, isTrue);
      expect(counts.historicalUnattributed, 1);
      expect(counts.reviewRequired, 1);
      expect(counts.ownerMismatch, 1);
      expect(counts.missingOwnership, 0);
      expect(counts.blocksDispatch, isTrue);
    },
  );
}
