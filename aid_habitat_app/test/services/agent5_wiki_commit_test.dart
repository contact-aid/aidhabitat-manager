import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';
import 'package:aid_habitat_app/services/wiki_sync_commit.dart' as wiki_sync;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late WikiRepository repository;
  var remaps = <String>[];
  Future<bool> commitWikiSyncResponse({
    required Database database,
    required SyncOperation operation,
    WikiItem? saved,
  }) => wiki_sync.commitWikiSyncResponse(
    database: database,
    operation: operation,
    saved: saved,
    remapReferences: (txn, oldId, newId) async {
      remaps.add('$oldId:$newId');
      await txn.insert('kv_store', {
        'key': 'synthetic-reference', 'value': newId,
        'updated_at': '2026-09-10T00:00:00.000Z',
      });
    },
  );
  const stamp = '2026-09-10T00:00:00.000Z';
  const draft = 'local_draft_test';
  WikiItem item(String id, String title) => WikiItem(
    id: id,
    title: title,
    description: title,
    imageUrl: 'https://synthetic.invalid/$title',
    tags: const [],
    category: '',
    createdAt: stamp,
    updatedAt: stamp,
  );
  Future<SyncOperation> seed({
    String id = draft,
    String type = 'create',
  }) async {
    await db.insert('wiki_items', {
      'id': id,
      'title': 'A',
      'description': 'A',
      'image_url': '',
      'tags_json': '[]',
      'category': '',
      'created_at': stamp,
      'updated_at': stamp,
      'last_synced_at': stamp,
      'sync_state': 'pendingSync',
    });
    final payload = jsonEncode({'title': 'A', 'description': 'A'});
    await db.insert('sync_operations', {
      'id': 'operation-A',
      'entity_type': 'wiki_item',
      'entity_local_id': id,
      'operation_type': type,
      'payload_json': payload,
      'status': 'running',
      'attempt_count': 0,
      'created_at': stamp,
      'updated_at': stamp,
    });
    return SyncOperation(
      id: 'operation-A',
      entityType: 'wiki_item',
      entityLocalId: id,
      operationType: type,
      payloadJson: payload,
      status: SyncOperationStatus.running,
      attemptCount: 0,
      createdAt: DateTime.parse(stamp),
      updatedAt: DateTime.parse(stamp),
    );
  }

  setUp(() async {
    remaps = [];
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = WikiRepository(database: local);
  });
  tearDown(() async => db.close());

  test(
    'create A, edit B and image B, response A preserves B and remaps update',
    () async {
      final op = await seed();
      await repository.updateLocalItem(
        item(draft, 'B'),
        imageDataUrl: 'data:image/png;base64,Qg==',
      );
      final before = await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: [op.id],
      );
      expect(before.single['status'], 'running');
      expect(before.single['payload_json'], op.payloadJson);
      expect(
        await commitWikiSyncResponse(
          database: db,
          operation: op,
          saved: item('remote-1', 'A'),
        ),
        isTrue,
      );
      final row = (await db.query('wiki_items')).single;
      expect(row['id'], 'remote-1');
      expect(row['title'], 'B');
      expect(row['pending_image_data_url'], 'data:image/png;base64,Qg==');
      expect(row['sync_state'], 'pendingSync');
      final next = (await db.query(
        'sync_operations',
        where: 'status = ?',
        whereArgs: ['pending'],
      )).single;
      expect(next['entity_local_id'], 'remote-1');
      expect(next['operation_type'], 'update');
      expect(jsonDecode(next['payload_json'] as String)['itemId'], 'remote-1');
      expect(
        await commitWikiSyncResponse(
          database: db,
          operation: op,
          saved: item('remote-1', 'A'),
        ),
        isFalse,
      );
    },
  );

  test(
    'delete while creation is running preserves tombstone and remaps delete',
    () async {
      final op = await seed();
      await repository.deleteLocalItem(draft);
      expect((await db.query('wiki_items')).single['pending_delete'], 1);
      expect(
        await commitWikiSyncResponse(
          database: db,
          operation: op,
          saved: item('remote-1', 'A'),
        ),
        isTrue,
      );
      final row = (await db.query('wiki_items')).single;
      expect(row['id'], 'remote-1');
      expect(row['pending_delete'], 1);
      final next = (await db.query(
        'sync_operations',
        where: 'status = ?',
        whereArgs: ['pending'],
      )).single;
      expect(next['operation_type'], 'delete');
      expect(jsonDecode(next['payload_json'] as String)['itemId'], 'remote-1');
    },
  );

  test('late update preserves newer fields and image', () async {
    final op = await seed(id: 'remote-1', type: 'update');
    await repository.updateLocalItem(
      item('remote-1', 'B'),
      imageDataUrl: 'data:image/png;base64,Qg==',
    );
    await commitWikiSyncResponse(
      database: db,
      operation: op,
      saved: item('remote-1', 'A'),
    );
    final row = (await db.query('wiki_items')).single;
    expect(row['title'], 'B');
    expect(row['sync_state'], 'pendingSync');
    expect(row['pending_image_data_url'], 'data:image/png;base64,Qg==');
  });

  for (final state in ['pendingSync', 'syncError', 'conflict']) {
    test('future remote clock preserves local $state without an operation', () async {
      await seed(id: 'remote-1', type: 'update');
      await db.delete('sync_operations');
      await db.update('wiki_items', {
        'sync_state': state, 'pending_image_data_url': 'image-B',
      });
      final before = await db.query('wiki_items');
      await repository.mergeRemoteItems([
        item('remote-1', 'REMOTE').copyWith(
          imageUrl: '', updatedAt: '2099-01-01T00:00:00Z'),
      ]);
      expect(await db.query('wiki_items'), before);
    });
  }

  for (final status in ['pending', 'running', 'failed', 'conflict']) {
    test('queue $status protects incorrectly synced row and remote deletion', () async {
      await seed(id: 'remote-1', type: 'update');
      await db.update('wiki_items', {'sync_state': 'synced'});
      await db.update('sync_operations', {'status': status});
      final before = await db.query('wiki_items');
      final queue = await db.query('sync_operations');
      await repository.mergeRemoteItems([
        item('remote-1', 'REMOTE').copyWith(
          imageUrl: '', updatedAt: '2099-01-01T00:00:00Z'),
      ]);
      expect(await db.query('wiki_items'), before);
      await repository.mergeRemoteItems([
        item('another-item', 'OTHER').copyWith(imageUrl: ''),
      ]);
      expect(await db.query('wiki_items', where: 'id = ?',
        whereArgs: ['remote-1']), before);
      expect(await db.query('sync_operations'), queue);
    });
  }

  test('confirmed row still accepts remote update', () async {
    await seed(id: 'remote-1', type: 'update');
    await db.update('wiki_items', {'sync_state': 'synced'});
    await db.update('sync_operations', {'status': 'completed'});
    await repository.mergeRemoteItems([
      item('remote-1', 'REMOTE').copyWith(imageUrl: ''),
    ]);
    expect((await db.query('wiki_items')).single['title'], 'REMOTE');
  });

  test('modified claim rejects response without rewriting row', () async {
    final op = await seed();
    await db.update('sync_operations', {'payload_json': '{}'});
    expect(
      await commitWikiSyncResponse(
        database: db,
        operation: op,
        saved: item('remote-1', 'A'),
      ),
      isFalse,
    );
    expect((await db.query('wiki_items')).single['id'], draft);
  });

  test('uncontested response acknowledges and clears pending image', () async {
    final op = await seed();
    await commitWikiSyncResponse(
      database: db,
      operation: op,
      saved: item('remote-1', 'A'),
    );
    expect((await db.query('wiki_items')).single['sync_state'], 'synced');
    expect((await db.query('sync_operations')).single['status'], 'completed');
    expect(remaps, ['$draft:remote-1']);
    expect((await db.query('kv_store')).single['value'], 'remote-1');
  });

  test(
    'stale open draft cannot silently enqueue an update after remap',
    () async {
      final op = await seed();
      await commitWikiSyncResponse(
        database: db,
        operation: op,
        saved: item('remote-1', 'A'),
      );
      await expectLater(
        repository.updateLocalItem(item(draft, 'B')),
        throwsStateError,
      );
      expect(await db.query('sync_operations'), hasLength(1));
      expect((await db.query('wiki_items')).single['title'], 'A');
    },
  );

  test(
    'deleting an existing item with a pending update queues remote deletion',
    () async {
      await seed(id: 'remote-1', type: 'update');
      await db.update('sync_operations', {'status': 'pending'});
      await repository.deleteLocalItem('remote-1');
      expect((await db.query('wiki_items')).single['pending_delete'], 1);
      expect(
        (await db.query('sync_operations')).single['operation_type'],
        'delete',
      );
      await expectLater(
        repository.updateLocalItem(item('remote-1', 'B')),
        throwsStateError,
      );
    },
  );

  test(
    'failure at acknowledgement rolls back row and follow-up remap',
    () async {
      final op = await seed();
      await repository.updateLocalItem(item(draft, 'B'));
      await db.execute(
        "CREATE TRIGGER fail_ack BEFORE UPDATE ON sync_operations "
        "WHEN NEW.status = 'completed' BEGIN SELECT RAISE(ABORT, 'test'); END",
      );
      await expectLater(
        commitWikiSyncResponse(
          database: db,
          operation: op,
          saved: item('remote-1', 'A'),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await db.query('wiki_items')).single['id'], draft);
    expect((await db.query('wiki_items')).single['title'], 'B');
    expect(await db.query('kv_store'), isEmpty);
      expect(
        (await db.query(
          'sync_operations',
        )).every((row) => row['entity_local_id'] == draft),
        isTrue,
      );
    },
  );
}
