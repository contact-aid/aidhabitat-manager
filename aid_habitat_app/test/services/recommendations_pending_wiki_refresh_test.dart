import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test(
    'repeated remote refreshes preserve a recommendation awaiting wiki upload',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repository = DossierRepository(database: local);
      const pending = {
        'id': 'pending',
        'wikiItemId': 'local_draft_photo',
        'wikiTitle': 'Mains courantes',
        'wikiImageUrl': 'data:image/png;base64,pending',
      };
      const remote = {'id': 'published', 'wikiItemId': 'wiki-published'};
      await db.insert('visit_recommendations', {
        'local_id': 'rec-test',
        'dossier_local_id': 'dossier-test',
        'items_json': jsonEncode([remote, pending]),
        'sync_state': 'pendingSync',
        'updated_at': '2026-11-04T09:00:00Z',
      });
      for (var i = 0; i < 3; i++) {
        expect(
          await repository.mergeRemoteVisitRecommendationsPayload(
            'dossier-test',
            [remote],
            remoteRevision: '00000000-0000-4000-8000-000000000001',
            remoteSnapshotExists: true,
          ),
          isTrue,
        );
        final items = await repository.fetchVisitRecommendations(
          'dossier-test',
        );
        expect(items.map((item) => item.id), ['published', 'pending']);
        expect(items.last.wikiImageUrl, pending['wikiImageUrl']);
      }
      expect(await db.query('sync_operations'), isEmpty);
    },
  );
}
