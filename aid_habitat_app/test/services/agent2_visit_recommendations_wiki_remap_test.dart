import 'dart:convert';

import 'package:aid_habitat_app/services/visit_recommendations_wiki_remap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const oldWikiId = 'local_draft_42';
const newWikiId = 'wiki-created';
const oldWriteId = '00000000-0000-4000-8000-000000000001';
const newWriteId = '00000000-0000-4000-8000-000000000002';

Future<Database> openTestDatabase() async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
  await db.execute('''
    CREATE TABLE visit_recommendations (
      local_id TEXT PRIMARY KEY,
      dossier_local_id TEXT NOT NULL UNIQUE,
      items_json TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      sync_state TEXT NOT NULL
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
      attempt_count INTEGER NOT NULL,
      last_error TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  return db;
}

Map<String, dynamic> recommendation(String id, String wikiItemId) => {
  'id': id,
  'wikiItemId': wikiItemId,
  'note': 'note-$id',
};

Map<String, dynamic> queuedPayload(List<Map<String, dynamic>> items) => {
  'dossierId': 'dossier-1',
  'updates': {'items': items},
  'items': items,
  'concurrency': {
    'version': 1,
    'writeId': oldWriteId,
    'baseValues': <String, dynamic>{'items': items},
    'expectedUpdatedAt': null,
  },
};

Future<void> insertRecommendations(
  Database db,
  List<Map<String, dynamic>> items,
) => db.insert('visit_recommendations', {
  'local_id': 'rec-1',
  'dossier_local_id': 'dossier-1',
  'items_json': jsonEncode(items),
  'updated_at': '2026-09-10T08:00:00.000Z',
  'sync_state': 'pendingSync',
});

Future<void> insertOperation(
  Database db, {
  required String id,
  required String status,
  required Map<String, dynamic> payload,
}) => db.insert('sync_operations', {
  'id': id,
  'entity_type': 'visit_recommendations',
  'entity_local_id': 'dossier-1',
  'operation_type': 'update',
  'payload_json': jsonEncode(payload),
  'status': status,
  'attempt_count': 0,
  'last_error': null,
  'created_at': '2026-09-10T08:00:00.000Z',
  'updated_at': '2026-09-10T08:00:00.000Z',
});

Future<String> identity(String value) async => value;

void main() {
  late Database db;

  setUp(() async {
    db = await openTestDatabase();
  });

  tearDown(() async {
    await db.close();
  });

  test('agent2 remap and pending publication are committed together', () async {
    final draft = recommendation('draft', '');
    final pending = recommendation('pending-wiki', oldWikiId);
    final published = recommendation('published', 'wiki-existing');
    await insertRecommendations(db, [draft, pending, published]);
    await insertOperation(
      db,
      id: 'visitrec_update_dossier-1',
      status: 'pending',
      payload: queuedPayload([pending, published]),
    );

    final result = await db.transaction(
      (txn) => remapVisitRecommendationReferencesInTransaction(
        txn,
        oldWikiId,
        newWikiId,
        openPayload: identity,
        sealPayload: identity,
        createWriteId: () => newWriteId,
        clock: () => DateTime.utc(2026, 9, 10, 9),
      ),
    );

    final localItems =
        (jsonDecode(
                  (await db.query('visit_recommendations')).single['items_json']
                      as String,
                )
                as List)
            .cast<Map>();
    expect(localItems.map((item) => item['wikiItemId']), [
      '',
      newWikiId,
      'wiki-existing',
    ]);

    final operation = (await db.query('sync_operations')).single;
    final payload = jsonDecode(operation['payload_json'] as String) as Map;
    expect((payload['items'] as List).map((item) => item['wikiItemId']), [
      newWikiId,
      'wiki-existing',
    ]);
    expect(payload['concurrency']['writeId'], newWriteId);
    expect(
      payload['concurrency']['baseValues']['items'][0]['wikiItemId'],
      oldWikiId,
    );
    expect(
      (await db.query('visit_recommendations')).single['sync_state'],
      'pendingSync',
    );
    expect(result.rowsChanged, 1);
    expect(result.operationsChanged, 1);
    expect(result.operationsCreated, 0);
    expect(result.shouldNotifySync, isTrue);
  });

  test(
    'agent2 running payload with local wiki id aborts the transaction',
    () async {
      final pending = recommendation('pending-wiki', oldWikiId);
      await insertRecommendations(db, [pending]);
      await insertOperation(
        db,
        id: 'running-op',
        status: 'running',
        payload: queuedPayload([pending]),
      );

      await expectLater(
        db.transaction(
          (txn) => remapVisitRecommendationReferencesInTransaction(
            txn,
            oldWikiId,
            newWikiId,
            openPayload: identity,
            sealPayload: identity,
            createWriteId: () => newWriteId,
          ),
        ),
        throwsStateError,
      );

      final row = (await db.query('visit_recommendations')).single;
      expect(row['items_json'], contains(oldWikiId));
      final operation = (await db.query('sync_operations')).single;
      expect(operation['payload_json'], contains(oldWikiId));
      expect(operation['status'], 'running');
    },
  );

  test(
    'agent2 running operation stays immutable and gets a durable follow-up',
    () async {
      final pending = recommendation('pending-wiki', oldWikiId);
      final alreadyPublished = recommendation('published', 'wiki-existing');
      await insertRecommendations(db, [pending, alreadyPublished]);
      await insertOperation(
        db,
        id: 'running-op',
        status: 'running',
        payload: queuedPayload([alreadyPublished]),
      );
      final runningBefore = (await db.query('sync_operations')).single;

      final result = await db.transaction(
        (txn) => remapVisitRecommendationReferencesInTransaction(
          txn,
          oldWikiId,
          newWikiId,
          openPayload: identity,
          sealPayload: identity,
          createWriteId: () => newWriteId,
        ),
      );

      final operations = await db.query('sync_operations', orderBy: 'id');
      expect(operations, hasLength(2));
      final running = operations.singleWhere(
        (row) => row['id'] == 'running-op',
      );
      expect(running['payload_json'], runningBefore['payload_json']);
      expect(running['status'], 'running');
      final followUp = operations.singleWhere(
        (row) => row['status'] == 'pending',
      );
      final payload = jsonDecode(followUp['payload_json'] as String) as Map;
      expect((payload['items'] as List).map((item) => item['wikiItemId']), [
        newWikiId,
        'wiki-existing',
      ]);
      expect(payload['localReference']['writeId'], newWriteId);
      expect(payload.containsKey('concurrency'), isFalse);
      expect(result.operationsCreated, 1);
    },
  );

  test(
    'agent2 conflict payload is remapped without clearing conflict',
    () async {
      final pending = recommendation('pending-wiki', oldWikiId);
      await insertRecommendations(db, [pending]);
      await insertOperation(
        db,
        id: 'conflict-op',
        status: 'conflict',
        payload: queuedPayload([pending]),
      );

      final result = await db.transaction(
        (txn) => remapVisitRecommendationReferencesInTransaction(
          txn,
          oldWikiId,
          newWikiId,
          openPayload: identity,
          sealPayload: identity,
          createWriteId: () => newWriteId,
        ),
      );

      final operation = (await db.query('sync_operations')).single;
      expect(operation['status'], 'conflict');
      expect(operation['payload_json'], contains(newWikiId));
      final payload = jsonDecode(operation['payload_json'] as String) as Map;
      expect(payload['items'].toString(), isNot(contains(oldWikiId)));
      expect(
        payload['concurrency']['baseValues'].toString(),
        contains(oldWikiId),
      );
      expect(
        (await db.query('visit_recommendations')).single['sync_state'],
        'conflict',
      );
      expect(result.requiresManualResolution, isTrue);
      expect(result.operationsCreated, 0);
    },
  );

  test('agent2 incomplete future envelope aborts before local remap', () async {
    final pending = recommendation('pending-wiki', oldWikiId);
    await insertRecommendations(db, [pending]);
    await insertOperation(
      db,
      id: 'future-op',
      status: 'pending',
      payload: {
        'envelope': {
          'protocolVersion': 1,
          'writeId': oldWriteId,
          'items': [pending],
        },
      },
    );

    await expectLater(
      db.transaction(
        (txn) => remapVisitRecommendationReferencesInTransaction(
          txn,
          oldWikiId,
          newWikiId,
          openPayload: identity,
          sealPayload: identity,
          createWriteId: () => newWriteId,
        ),
      ),
      throwsStateError,
    );

    expect(
      (await db.query('visit_recommendations')).single['items_json'],
      contains(oldWikiId),
    );
  });
}
