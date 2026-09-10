import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('failed sealing cannot validate the web migration marker', () async {
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    for (final name in [
      'trg_sync_operation_owner_before_insert',
      'trg_sync_operation_owner_after_insert',
      'trg_sync_operation_owner_before_payload_update',
      'trg_sync_operation_owner_payload_update',
    ]) {
      await db.execute('DROP TRIGGER $name');
    }
    await db.insert('sync_operations', {
      'id': 'legacy',
      'entity_type': 'document',
      'entity_local_id': 'doc',
      'operation_type': 'update',
      'payload_json': 'legacy-cleartext',
      'status': 'pending',
      'created_at': '2026-09-10',
      'updated_at': '2026-09-10',
    });
    await db.insert('reference_sync_meta', {
      'table_name': '__offline_vault_web_v1',
      'last_synced_at': '2026-09-09',
    });
    for (var index = 0; index < 2; index++) {
      await db.insert('sync_operation_ownership_history', {
        'operation_id': 'legacy-$index',
        'owner_user_local_id': null,
        'payload_json': 'history-$index',
        'operation_updated_at': '2026-09-09',
        'reason': 'synthetic',
        'captured_at': '2026-09-09',
      });
    }
    final failure = StateError('Synthetic encryption failure');
    await expectLater(
      local.sealWebOfflineVaultForTesting((_) async => throw failure),
      throwsA(same(failure)),
    );
    expect(
      await db.query(
        'reference_sync_meta',
        where: 'table_name = ?',
        whereArgs: ['__offline_vault_web_v2'],
      ),
      isEmpty,
    );
    expect(
      (await db.query('sync_operations')).single['payload_json'],
      'legacy-cleartext',
    );
    await local.sealWebOfflineVaultForTesting((value) async => 'sealed:$value');
    expect(
      (await db.query('sync_operations')).single['payload_json'],
      'sealed:legacy-cleartext',
    );
    expect(
      (await db.query(
        'sync_operation_ownership_history',
        orderBy: 'id',
      )).map((row) => row['payload_json']),
      ['sealed:history-0', 'sealed:history-1'],
    );
    expect(
      await db.query(
        'reference_sync_meta',
        where: 'table_name = ?',
        whereArgs: ['__offline_vault_web_v2'],
      ),
      hasLength(1),
    );
  });
}
