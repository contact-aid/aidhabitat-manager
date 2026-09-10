import 'dart:io';

import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(sqfliteFfiInit);

  Future<void> createV23Queue(Database db) async {
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
  }

  Future<void> insertOperation(
    Database db, {
    required String id,
    required String payload,
    required String status,
  }) async {
    await db.insert('sync_operations', {
      'id': id,
      'entity_type': 'dossier',
      'entity_local_id': 'dossier-$id',
      'operation_type': 'update',
      'payload_json': payload,
      'status': status,
      'attempt_count': status == 'running' ? 1 : 0,
      'last_error': status == 'conflict' ? 'synthetic conflict' : null,
      'created_at': '2026-09-10T08:00:00.000Z',
      'updated_at': '2026-09-10T08:01:00.000Z',
    });
  }

  test(
    'v23 to v24 preserves queued payloads and invents no historical owner',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await createV23Queue(db);
      await db.insert('app_session', {'id': 1, 'user_local_id': 'user-active'});
      await insertOperation(
        db,
        id: 'pending-file',
        payload: '{"file":"sealed-file-payload"}',
        status: 'pending',
      );
      await insertOperation(
        db,
        id: 'running-note',
        payload: '{"note":"sealed-running-payload"}',
        status: 'running',
      );
      await insertOperation(
        db,
        id: 'conflict-child',
        payload: '{"child":"sealed-conflict-payload"}',
        status: 'conflict',
      );

      await LocalDatabase.forTesting(db).upgradeSchemaForTesting(23);

      final operations = await db.query('sync_operations', orderBy: 'id');
      expect(
        operations.map(
          (row) => (row['id'], row['status'], row['payload_json']),
        ),
        [
          ('conflict-child', 'conflict', '{"child":"sealed-conflict-payload"}'),
          ('pending-file', 'pending', '{"file":"sealed-file-payload"}'),
          ('running-note', 'running', '{"note":"sealed-running-payload"}'),
        ],
      );
      final ownership = await db.query(
        SyncOperationOwnership.tableName,
        orderBy: 'operation_id',
      );
      expect(ownership, hasLength(3));
      for (final row in ownership) {
        expect(row['owner_user_local_id'], isNull);
        expect(row['candidate_user_local_id'], isNull);
        expect(
          row['attribution_state'],
          SyncOperationOwnership.historicalUnattributed,
        );
      }
    },
  );

  test('fresh enqueue captures the active app session', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await createV23Queue(db);
    await LocalDatabase.forTesting(db).upgradeSchemaForTesting(23);
    await db.insert('app_session', {'id': 1, 'user_local_id': 'user-a'});

    await insertOperation(
      db,
      id: 'fresh',
      payload: '{"fresh":true}',
      status: 'pending',
    );

    final owner = (await db.query(
      SyncOperationOwnership.tableName,
      where: 'operation_id = ?',
      whereArgs: ['fresh'],
    )).single;
    expect(owner['owner_user_local_id'], 'user-a');
    expect(
      owner['attribution_state'],
      SyncOperationOwnership.capturedAtEnqueue,
    );
  });

  test('cross-account replacement history survives database reopen', () async {
    final directory = await Directory.systemTemp.createTemp(
      'agent4-ownership-reopen-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/ownership.sqlite';
    var db = await databaseFactoryFfi.openDatabase(path);
    await createV23Queue(db);
    await LocalDatabase.forTesting(db).upgradeSchemaForTesting(23);
    await db.insert('app_session', {'id': 1, 'user_local_id': 'user-a'});
    await insertOperation(
      db,
      id: 'shared',
      payload: '{"value":"a"}',
      status: 'pending',
    );
    await db.update('app_session', {
      'user_local_id': 'user-b',
    }, where: 'id = 1');
    await db.insert('sync_operations', {
      'id': 'shared',
      'entity_type': 'dossier',
      'entity_local_id': 'dossier-shared',
      'operation_type': 'update',
      'payload_json': '{"value":"b"}',
      'status': 'pending',
      'attempt_count': 0,
      'last_error': null,
      'created_at': '2026-09-10T08:02:00.000Z',
      'updated_at': '2026-09-10T08:03:00.000Z',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.close();

    db = await databaseFactoryFfi.openDatabase(path);
    addTearDown(db.close);
    final current = (await db.query(
      'sync_operations',
      where: 'id = ?',
      whereArgs: ['shared'],
    )).single;
    final history = (await db.query(
      SyncOperationOwnership.historyTableName,
      where: 'operation_id = ?',
      whereArgs: ['shared'],
    )).single;
    expect(current['payload_json'], '{"value":"b"}');
    expect(history['owner_user_local_id'], 'user-a');
    expect(history['payload_json'], '{"value":"a"}');
  });
}
