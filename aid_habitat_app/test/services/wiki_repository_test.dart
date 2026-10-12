import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database db;
  late WikiRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final localDatabase = LocalDatabase.forTesting(db);
    await localDatabase.createSchemaForTesting();
    repository = WikiRepository(database: localDatabase);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertSyncedWikiItem(String id) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('wiki_items', {
      'id': id,
      'title': 'Barre d’appui',
      'description': 'Description terrain',
      'image_url': '/wiki-access.svg',
      'tags_json': jsonEncode(['Salle de bain']),
      'category': 'Salle de bain',
      'created_at': now,
      'updated_at': now,
      'last_synced_at': now,
      'pending_image_data_url': null,
      'sync_state': SyncState.synced.name,
      'pending_delete': 0,
    });
  }

  test(
    'deleteLocalItem masque un élément synchronisé et enqueue le DELETE',
    () async {
      await insertSyncedWikiItem('wiki-1');

      await repository.deleteLocalItem('wiki-1');

      expect(await repository.fetchAllItems(), isEmpty);

      final itemRows = await db.query(
        'wiki_items',
        where: 'id = ?',
        whereArgs: const ['wiki-1'],
      );
      expect(itemRows, hasLength(1));
      expect(itemRows.single['pending_delete'], 1);
      expect(itemRows.single['sync_state'], SyncState.pendingSync.name);

      final operationRows = await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: const ['wiki_delete_wiki-1'],
      );
      expect(operationRows, hasLength(1));
      expect(operationRows.single['entity_type'], 'wiki_item');
      expect(operationRows.single['operation_type'], 'delete');

      final payload =
          jsonDecode(operationRows.single['payload_json'] as String)
              as Map<String, dynamic>;
      expect(payload['itemId'], 'wiki-1');
    },
  );

  test(
    'deleteLocalItem purge un brouillon local sans DELETE distant',
    () async {
      final draft = await repository.createLocalDraft(
        title: 'Siège de douche',
        description: 'Description',
        category: 'Salle de bain',
        tags: const ['Salle de bain'],
        imageUrl: '/wiki-bathroom.svg',
      );

      await repository.deleteLocalItem(draft.id);

      expect(await db.query('wiki_items'), isEmpty);
      expect(await db.query('sync_operations'), isEmpty);
    },
  );
  test(
    'library and report edits share a versioned publication and preserve overrides',
    () async {
      await insertSyncedWikiItem('wiki-1');
      const revision = '00000000-0000-4000-8000-000000000001';
      final items = [
        const VisitRecommendationItem(
          id: 'linked',
          wikiItemId: 'wiki-1',
          wikiTitle: 'Barre d’appui',
          wikiDescription: 'Description terrain',
        ),
        const VisitRecommendationItem(
          id: 'custom',
          wikiItemId: 'wiki-1',
          wikiTitle: 'Barre d’appui',
          customTitle: 'Mon titre',
          note: 'Mon argumentaire',
        ),
        const VisitRecommendationItem(id: 'draft'),
      ];
      await db.insert('visit_recommendations', {
        'local_id': 'rec-1',
        'dossier_local_id': 'dossier-1',
        'items_json': jsonEncode(items.map((item) => item.toJson()).toList()),
        'remote_snapshot_exists': 1,
        'remote_revision': revision,
        'updated_at': DateTime.now().toIso8601String(),
        'sync_state': SyncState.synced.name,
      });
      final wiki = (await repository.fetchAllItems()).single;
      await repository.updateLocalItem(
        wiki.copyWith(
          title: 'Nouveau titre',
          description: 'Nouvelle description',
        ),
      );
      final operations = await db.query(
        'sync_operations',
        where: 'entity_type = ?',
        whereArgs: ['visit_recommendations'],
      );
      expect(operations, hasLength(1));
      final payload =
          jsonDecode(operations.single['payload_json'] as String) as Map;
      final envelope = payload['envelope'] as Map;
      expect(envelope['protocolVersion'], 1);
      expect(envelope['expectedRevision'], revision);
      expect(envelope['writeId'], isNotEmpty);
      expect(envelope['items'], hasLength(2));
      expect((envelope['items'] as List)[1]['note'], 'Mon argumentaire');
      expect((envelope['items'] as List)[1]['customTitle'], 'Mon titre');
      final reports = DossierRepository(database: LocalDatabase.forTesting(db));
      final local = await reports.fetchVisitRecommendations('dossier-1');
      expect(local, hasLength(3));
      expect(local.first.wikiDescription, 'Nouvelle description');
      await reports.saveVisitRecommendations('dossier-1', [
        local.first.copyWith(note: 'Modification du rapport'),
        ...local.skip(1),
      ]);
      final latest = (await db.query(
        'sync_operations',
        where: 'entity_type = ?',
        whereArgs: ['visit_recommendations'],
      )).single;
      final latestPayload = jsonDecode(latest['payload_json'] as String) as Map;
      expect(
        latestPayload['envelope']['items'][0]['note'],
        'Modification du rapport',
      );
      expect(latestPayload['envelope']['expectedRevision'], revision);
      await repository.updateLocalItem(
        wiki.copyWith(title: 'Titre final', description: 'Description finale'),
      );
      final finalItems = await reports.fetchVisitRecommendations('dossier-1');
      expect(finalItems.first.note, 'Modification du rapport');
      expect(finalItems.first.wikiDescription, 'Description finale');
      final finalOperation = (await db.query(
        'sync_operations',
        where: 'entity_type = ?',
        whereArgs: ['visit_recommendations'],
      )).single;
      expect(finalOperation['status'], SyncOperationStatus.pending.name);
      final finalPayload =
          jsonDecode(finalOperation['payload_json'] as String) as Map;
      expect(finalPayload['envelope']['protocolVersion'], 1);
      expect(
        finalPayload['envelope']['items'][0]['note'],
        'Modification du rapport',
      );
    },
  );
}
