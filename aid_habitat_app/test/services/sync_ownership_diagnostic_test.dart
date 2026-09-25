import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Regression coverage derived from the ownership incident characterization.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  late SyncRepository queue;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE app_session (id INTEGER PRIMARY KEY, user_local_id TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE app_users (local_id TEXT PRIMARY KEY, display_name TEXT NOT NULL)',
    );
    await db.execute('''CREATE TABLE sync_operations (
      id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_local_id TEXT NOT NULL,
      operation_type TEXT NOT NULL, payload_json TEXT NOT NULL, status TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
    queue = SyncRepository(databaseProvider: () async => db);
  });
  tearDown(() => db.close());

  Future<void> user(String id) => db
      .insert('app_session', {
        'id': 1,
        'user_local_id': id,
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
  Future<void> write(
    String id, {
    String status = 'pending',
    String value = 'new',
  }) => db
      .insert('sync_operations', {
        'id': id,
        'entity_type': 'visit_recommendations',
        'entity_local_id': id,
        'operation_type': 'update',
        'payload_json': '{"items":[],"synthetic":"$value"}',
        'status': status,
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});

  test(
    'actual recommendation save starts fresh after completed historical work',
    () async {
      await db.execute('''CREATE TABLE visit_recommendations (
      local_id TEXT PRIMARY KEY, dossier_local_id TEXT, items_json TEXT,
      updated_at TEXT, remote_updated_at TEXT, sync_state TEXT)''');
      await user('ergo-a');
      await write('visitrec_update_synthetic', status: 'completed');
      await SyncOperationOwnership.installMigration(db);
      final repository = DossierRepository(
        database: LocalDatabase.forTesting(db),
      );
      await repository.saveVisitRecommendations('synthetic', const [
        VisitRecommendationItem(
          id: 'item',
          wikiItemId: 'wiki-synthetic',
          note: 'new note',
        ),
      ]);
      expect(
        await SyncOperationOwnership.mayClaim(db, 'visitrec_update_synthetic'),
        isTrue,
      );
      expect(await queue.fetchTopFailingOperation(), isNull);
      expect(
        (await db.query('visit_recommendations')).single['items_json'],
        contains('new note'),
      );
    },
  );
  test('ordinary successive edits by one author remain runnable', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('visitrec_update_synthetic');
    await write('visitrec_update_synthetic', value: 'second');
    expect(
      await SyncOperationOwnership.mayClaim(db, 'visitrec_update_synthetic'),
      isTrue,
    );
    expect(await queue.fetchTopFailingOperation(), isNull);
  });
  test(
    'explicit review can recover missing metadata without changing content',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await user('reviewer');
      await write('missing');
      await db.delete(SyncOperationOwnership.tableName);
      final original = (await db.query('sync_operations')).single;
      expect(await SyncOperationOwnership.mayClaim(db, 'missing'), isFalse);
      final accepted = await db.transaction(
        (txn) => SyncOperationOwnership.reviewAttribution(
          txn: txn,
          operationId: 'missing',
          expectedPayloadJson: original['payload_json'] as String,
          expectedPreviousOwnerUserLocalId: null,
        ),
      );
      expect(accepted, isTrue);
      expect(await SyncOperationOwnership.mayClaim(db, 'missing'), isTrue);
      expect((await db.query('sync_operations')).single, original);
    },
  );
  test('missing metadata review rejects changed payload', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('reviewer');
    await write('missing');
    await db.delete(SyncOperationOwnership.tableName);
    final accepted = await db.transaction(
      (txn) => SyncOperationOwnership.reviewAttribution(
        txn: txn,
        operationId: 'missing',
        expectedPayloadJson: 'stale',
        expectedPreviousOwnerUserLocalId: null,
      ),
    );
    expect(accepted, isFalse);
    expect(await db.query(SyncOperationOwnership.tableName), isEmpty);
  });
  test('confirmed work by A does not block a fresh edit by B', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('shared', status: 'completed');
    await user('ergo-b');
    await write('shared');
    expect(await SyncOperationOwnership.mayClaim(db, 'shared'), isTrue);
    expect(
      (await db.query(
        SyncOperationOwnership.tableName,
      )).single['owner_user_local_id'],
      'ergo-b',
    );
  });

  test('unknown orphan ownership is never automatically reassigned', () async {
    await write('orphan');
    await SyncOperationOwnership.installMigration(db);
    await db.delete('sync_operations');
    await user('ergo-a');
    await write('orphan');
    expect(await SyncOperationOwnership.mayClaim(db, 'orphan'), isFalse);
    expect(
      (await db.query(
        SyncOperationOwnership.tableName,
      )).single['owner_user_local_id'],
      isNull,
    );
  });

  test('a failed replacement rolls back the attribution renewal', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('shared', status: 'completed');
    await user('ergo-b');
    await db.execute(
      '''CREATE TRIGGER reject_test_insert BEFORE INSERT ON sync_operations
      BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END''',
    );
    await expectLater(write('shared'), throwsA(isA<DatabaseException>()));
    expect((await db.query('sync_operations')).single['status'], 'completed');
    expect(
      (await db.query(
        SyncOperationOwnership.tableName,
      )).single['owner_user_local_id'],
      'ergo-a',
    );
  });

  test('failed purge rolls back metadata cleanup', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('confirmed', status: 'completed');
    await db.execute(
      '''CREATE TRIGGER reject_test_delete BEFORE DELETE ON sync_operations
      BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END''',
    );
    await expectLater(
      queue.purgeCompleted(maxAge: Duration.zero),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.query('sync_operations'), hasLength(1));
    expect(await db.query(SyncOperationOwnership.tableName), hasLength(1));
  });

  test(
    'reinstalling triggers preserves pending attribution and history',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await user('ergo-a');
      await write('shared', value: 'a');
      await user('ergo-b');
      await write('shared', value: 'b');
      final owners = await db.query(SyncOperationOwnership.tableName);
      final history = await db.query(SyncOperationOwnership.historyTableName);
      await SyncOperationOwnership.installTriggers(db);
      await queue.purgeCompleted(maxAge: Duration.zero);
      expect(await db.query(SyncOperationOwnership.tableName), owners);
      expect(await db.query(SyncOperationOwnership.historyTableName), history);
      expect(await SyncOperationOwnership.mayClaim(db, 'shared'), isFalse);
    },
  );
  test('reused completed historical ID captures the new author', () async {
    await user('ergo-a');
    await write(
      'visitrec_update_synthetic',
      status: 'completed',
      value: 'confirmed-old',
    );
    await SyncOperationOwnership.installMigration(db);
    expect(await queue.fetchTopFailingOperation(), isNull);
    await write('visitrec_update_synthetic');
    expect(
      await SyncOperationOwnership.mayClaim(db, 'visitrec_update_synthetic'),
      isTrue,
    );
    expect(await queue.fetchTopFailingOperation(), isNull);
    final owner = (await db.query(SyncOperationOwnership.tableName)).single;
    expect(
      owner['attribution_state'],
      SyncOperationOwnership.capturedAtEnqueue,
    );
    expect(owner['owner_user_local_id'], 'ergo-a');
    expect(owner['candidate_user_local_id'], isNull);
    expect(await db.query(SyncOperationOwnership.historyTableName), isEmpty);
  });
  test(
    'completed row purge removes attribution before a new enqueue',
    () async {
      await write('visitrec_update_synthetic', status: 'completed');
      await SyncOperationOwnership.installMigration(db);
      await user('ergo-a');
      expect(await queue.purgeCompleted(maxAge: Duration.zero), 1);
      expect(await db.query('sync_operations'), isEmpty);
      expect(await db.query(SyncOperationOwnership.tableName), isEmpty);
      await write('visitrec_update_synthetic');
      expect(
        await SyncOperationOwnership.mayClaim(db, 'visitrec_update_synthetic'),
        isTrue,
      );
    },
  );
  test(
    'retry does not resolve attribution or delete pending payload',
    () async {
      await write('visitrec_update_synthetic');
      await SyncOperationOwnership.installMigration(db);
      await user('ergo-a');
      final before = await db.query('sync_operations');
      await queue.resetFailedToPending();
      expect(await queue.fetchRunnableOperations(), isEmpty);
      expect(await db.query('sync_operations'), before);
    },
  );
  test(
    'global warning can coexist with runnable work on a different dossier',
    () async {
      await write('legacy-dossier');
      await SyncOperationOwnership.installMigration(db);
      await user('ergo-a');
      await write('current-dossier');
      final runnable = await queue.fetchRunnableOperations(
        includePayloads: false,
      );
      expect(runnable.map((op) => op.entityLocalId), ['current-dossier']);
      expect(
        (await queue.fetchTopFailingOperation())!['entityType'],
        'sync_ownership',
      );
    },
  );
  test(
    'cross-author unconfirmed work stays protected and both intentions survive',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await user('ergo-a');
      await write('shared', value: 'author-a');
      await user('ergo-b');
      await write('shared', value: 'author-b');
      expect(await SyncOperationOwnership.mayClaim(db, 'shared'), isFalse);
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        contains('author-b'),
      );
      expect(
        (await db.query(
          SyncOperationOwnership.historyTableName,
        )).single['payload_json'],
        contains('author-a'),
      );
    },
  );
  test(
    'pending diagnostics identify the author without exposing their error',
    () async {
      await SyncOperationOwnership.installMigration(db);
      await db.insert('app_users', {
        'local_id': 'ergo-b',
        'display_name': 'Autrice B',
      });
      await user('ergo-a');
      await write('mine');
      await db.update(
        'sync_operations',
        {'status': 'failed', 'last_error': 'My server error'},
        where: 'id = ?',
        whereArgs: ['mine'],
      );
      await user('ergo-b');
      await write('theirs');
      await db.update(
        'sync_operations',
        {'status': 'failed', 'last_error': 'Private error for B'},
        where: 'id = ?',
        whereArgs: ['theirs'],
      );
      await user('ergo-a');

      final diagnostics = await queue.fetchPendingDiagnostics();
      expect(diagnostics.length, 2);
      expect(diagnostics[0].ownerState, 'current');
      expect(diagnostics[0].lastError, 'My server error');
      expect(diagnostics[1].ownerState, 'other');
      expect(diagnostics[1].ownerDisplayName, 'Autrice B');
      expect(diagnostics[1].lastError, isNull);
      expect((await db.query('sync_operations')).length, 2);
    },
  );
  test('only the original author can resume an aged running write', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('stuck', value: 'preserve this');
    final startedAt = DateTime.now()
        .subtract(const Duration(minutes: 6))
        .toIso8601String();
    await db.update(
      'sync_operations',
      {'status': 'running', 'updated_at': startedAt, 'attempt_count': 5},
      where: 'id = ?',
      whereArgs: ['stuck'],
    );
    final beforePayload = (await db.query(
      'sync_operations',
    )).single['payload_json'];
    final protectedQueue = SyncRepository(databaseProvider: () async => db);
    final diagnostic = (await protectedQueue.fetchPendingDiagnostics()).single;
    expect(diagnostic.canResume, isTrue);

    await user('ergo-b');
    expect(
      await protectedQueue.resumeStaleRunningOperation(
        operationId: 'stuck',
        observedUpdatedAt: startedAt,
      ),
      isFalse,
    );
    await user('ergo-a');
    expect(
      await protectedQueue.resumeStaleRunningOperation(
        operationId: 'stuck',
        observedUpdatedAt: startedAt,
      ),
      isTrue,
    );
    final after = (await db.query('sync_operations')).single;
    expect(after['status'], 'pending');
    expect(after['attempt_count'], 0);
    expect(after['payload_json'], beforePayload);
    expect(
      await protectedQueue.resumeStaleRunningOperation(
        operationId: 'stuck',
        observedUpdatedAt: startedAt,
      ),
      isFalse,
    );
  });
  test('only the author can restart a pending write without backoff', () async {
    await SyncOperationOwnership.installMigration(db);
    await user('ergo-a');
    await write('waiting', value: 'preserve this');
    await db.update(
      'sync_operations',
      {'attempt_count': 5, 'last_error': 'Remote update failed (503)'},
      where: 'id = ?',
      whereArgs: ['waiting'],
    );
    final queue = SyncRepository(databaseProvider: () async => db);
    final beforePayload = (await db.query(
      'sync_operations',
    )).single['payload_json'];
    await user('ergo-b');
    expect(await queue.retryPendingOperationNow('waiting'), isFalse);
    await user('ergo-a');
    expect(await queue.retryPendingOperationNow('waiting'), isTrue);
    final after = (await db.query('sync_operations')).single;
    expect(after['status'], 'pending');
    expect(after['attempt_count'], 0);
    expect(after['last_error'], isNull);
    expect(after['payload_json'], beforePayload);
  });
}
