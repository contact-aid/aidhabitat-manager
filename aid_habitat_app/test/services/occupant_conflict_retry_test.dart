import 'dart:convert';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SyncRepository repository;
  late String payload;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE kv_store(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT)',
    );
    await db.execute(
      'CREATE TABLE app_session(id INTEGER PRIMARY KEY, user_local_id TEXT)',
    );
    await db.execute(
      'CREATE TABLE patients(local_id TEXT PRIMARY KEY, sync_state TEXT)',
    );
    await db.execute(
      '''CREATE TABLE sync_operations(id TEXT PRIMARY KEY, entity_type TEXT,
      entity_local_id TEXT, operation_type TEXT, payload_json TEXT, status TEXT,
      attempt_count INTEGER, last_error TEXT, created_at TEXT, updated_at TEXT)''',
    );
    payload = jsonEncode({
      'patientLocalId': 'patient',
      'updates': {
        'occupants': [
          {'apa': true},
        ],
      },
      'concurrency': {
        'version': 1,
        'collectionContract': 'collections-v2',
        'writeId': '11111111-1111-4111-8111-111111111111',
        'baseValues': {
          'occupants': [
            {'apa': false},
          ],
        },
      },
      'conflict': {
        'remote': {'error': 'SYNC_FIELD_CONFLICT'},
      },
    });
    await db.insert('sync_operations', {
      'id': 'operation',
      'entity_type': 'patient',
      'entity_local_id': 'patient',
      'operation_type': 'update',
      'payload_json': payload,
      'status': 'conflict',
      'attempt_count': 1,
      'created_at': '2026-10-12',
      'updated_at': '2026-10-12',
    });
    await db.insert('patients', {
      'local_id': 'patient',
      'sync_state': 'conflict',
    });
    await SyncOperationOwnership.installMigration(db);
    await db.update(
      SyncOperationOwnership.tableName,
      {
        'owner_user_local_id': 'alice',
        'attribution_state': SyncOperationOwnership.capturedAtEnqueue,
      },
      where: 'operation_id = ?',
      whereArgs: ['operation'],
    );
    await db.insert('app_session', {'id': 1, 'user_local_id': 'alice'});
    repository = SyncRepository(databaseProvider: () async => db);
  });
  tearDown(() => db.close());
  test(
    'retry preserves original bytes, baseline, write id and owner',
    () async {
      expect(
        await repository.retryOriginalOccupantConflict(
          operationId: 'operation',
          expectedPayloadJson: payload,
        ),
        isTrue,
      );
      final row = (await db.query('sync_operations')).single;
      expect(row['status'], 'pending');
      expect(row['payload_json'], payload);
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['owner_user_local_id'],
        'alice',
      );
      expect((await db.query('patients')).single['sync_state'], 'pendingSync');
    },
  );
  test('a changed queue snapshot cannot be retried', () async {
    expect(
      await repository.retryOriginalOccupantConflict(
        operationId: 'operation',
        expectedPayloadJson: '$payload ',
      ),
      isFalse,
    );
    expect((await db.query('sync_operations')).single['status'], 'conflict');
  });
  test('another account cannot reopen the conflict', () async {
    await db.update('app_session', {'user_local_id': 'bob'});
    await expectLater(
      repository.retryOriginalOccupantConflict(
        operationId: 'operation',
        expectedPayloadJson: payload,
      ),
      throwsStateError,
    );
    expect((await db.query('sync_operations')).single['status'], 'conflict');
    expect((await db.query('patients')).single['sync_state'], 'conflict');
  });
}
