import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  const planPath = String.fromEnvironment('PRECO_IMPORT_PLAN');

  test(
    'imported photo descriptions and exact image bytes survive database reopening',
    () async {
      final dir = await Directory.systemTemp.createTemp('preco-offline-');
      final dbPath = '${dir.path}/library.sqlite';
      var db = await databaseFactoryFfi.openDatabase(dbPath);
      try {
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        final items = <WikiItem>[];
        if (planPath.isNotEmpty) {
          final plan = jsonDecode(await File(planPath).readAsString()) as Map;
          for (final item in (plan['items'] as List).where(
            (x) => x['action'] == 'create',
          )) {
            final bytes = await File(
              '${File(planPath).parent.path}/${item['imageFile']}',
            ).readAsBytes();
            items.add(
              WikiItem(
                id: item['id'],
                title: item['title'],
                description: item['description'],
                imageUrl: 'data:image/jpeg;base64,${base64Encode(bytes)}',
                tags: List<String>.from(item['tags']),
                category: item['category'],
                createdAt: '2026-09-15T00:00:00Z',
                updatedAt: '2026-09-15T00:00:00Z',
              ),
            );
          }
          expect(items, hasLength(175));
        } else {
          items.add(
            WikiItem(
              id: 'synthetic-photo',
              title: 'Siège douche mural',
              description:
                  'Assise de douche avec appuis à adapter au transfert.',
              imageUrl: 'data:image/jpeg;base64,/9j/2Q==',
              tags: ['Salle de bain'],
              category: 'Salle de bain',
              createdAt: '2026-09-15T00:00:00Z',
              updatedAt: '2026-09-15T00:00:00Z',
            ),
          );
        }
        await WikiRepository(database: local).mergeRemoteItems(items);
        await db.close();
        db = await databaseFactoryFfi.openDatabase(dbPath);
        final reopened = WikiRepository(database: LocalDatabase.forTesting(db));
        final loaded = await reopened.fetchAllItems();
        expect(loaded, hasLength(items.length));
        for (final original in items) {
          final restored = loaded.singleWhere((item) => item.id == original.id);
          expect(restored.title, original.title);
          expect(restored.description, original.description);
          expect(restored.imageUrl, original.imageUrl);
          expect(restored.tags, original.tags);
        }
        expect(await db.query('sync_operations'), isEmpty);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
