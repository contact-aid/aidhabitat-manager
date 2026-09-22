import 'dart:convert';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'v24 upgrade preserves context and queue without inventing a reference',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE contexte_de_vie (local_id TEXT PRIMARY KEY, medical_context_json TEXT, sync_state TEXT)',
      );
      await db.execute(
        'CREATE TABLE sync_operations (id TEXT PRIMARY KEY, payload_json TEXT)',
      );
      await db.insert('contexte_de_vie', {
        'local_id': 'context',
        'medical_context_json': '{"pathology":"pending"}',
        'sync_state': 'pendingSync',
      });
      await db.insert('sync_operations', {
        'id': 'op',
        'payload_json': '{"unchanged":true}',
      });
      await LocalDatabase.forTesting(db).upgradeSchemaForTesting(24);
      final row = (await db.query('contexte_de_vie')).single;
      expect(row['medical_context_json'], '{"pathology":"pending"}');
      expect(row['remote_reference_json'], isNull);
      expect(row['remote_reference_known'], 0);
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        '{"unchanged":true}',
      );
    },
  );

  test(
    'context ACK stores only its own reference and completes the exact mutation',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      const stamp = '2026-09-01T00:00:00Z';
      await db.insert('contexte_de_vie', {
        'local_id': 'context',
        'dossier_local_id': 'dossier',
        'updated_at': stamp,
        'sync_state': 'pendingSync',
      });
      const payload = '{"updates":{"medicalContext":{"pathology":"new"}}}';
      await db.insert('sync_operations', {
        'id': 'op',
        'entity_type': 'contexte_de_vie',
        'entity_local_id': 'dossier',
        'operation_type': 'update',
        'payload_json': payload,
        'status': 'running',
        'created_at': stamp,
        'updated_at': stamp,
      });
      final op = SyncOperation(
        id: 'op',
        entityType: 'contexte_de_vie',
        entityLocalId: 'dossier',
        operationType: 'update',
        payloadJson: payload,
        status: SyncOperationStatus.running,
        attemptCount: 0,
        createdAt: DateTime.parse(stamp),
        updatedAt: DateTime.parse(stamp),
      );
      final ref = jsonEncode({
        'recordId': 11,
        'revision': '11111111-1111-4111-8111-111111111111',
      });
      expect(
        await SyncRepository.forTesting(
          database: local,
        ).acknowledgeVersionedMutation(op, ref),
        isTrue,
      );
      final row = (await db.query('contexte_de_vie')).single;
      expect(row['remote_reference_json'], ref);
      expect(row['remote_reference_known'], 1);
      expect(row['sync_state'], 'synced');
      expect((await db.query('sync_operations')).single['status'], 'completed');
    },
  );
}
