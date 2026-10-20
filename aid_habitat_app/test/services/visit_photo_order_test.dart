import 'dart:convert';
import 'dart:io';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late Database db;
  DocumentRepository repository() => DocumentRepository(
    database: LocalDatabase.forTesting(db),
    prefetchRemoteAssets: false,
  );
  const timestamp = '2026-10-01T10:00:00.000Z';
  Future<void> photo(
    String id, {
    String tag = 'Visite - Accessibilité',
    int? rank,
    String created = timestamp,
  }) async {
    await db.insert('documents', {
      'local_id': id,
      'patient_local_id': 'patient',
      'dossier_local_id': 'dossier',
      'title': id,
      'file_name': '$id.jpg',
      'file_ext': 'jpg',
      'mime_type': 'image/jpeg',
      'tags_json': jsonEncode([tag]),
      'category_order': rank,
      'remote_file_path': '/api/mobile-documents/$id/content',
      'sync_state': 'synced',
      'created_at': created,
      'updated_at': timestamp,
    });
  }

  Future<List<String>> order() async => (await db.query(
    'documents',
    where: "tags_json LIKE '%Accessibilité%' AND pending_delete = 0",
    orderBy: 'category_order ASC',
  )).map((row) => row['local_id'] as String).toList();
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('visit-photo-order-');
    db = await databaseFactoryFfi.openDatabase(
      '${directory.path}/photos.sqlite',
    );
    await LocalDatabase.forTesting(db).createSchemaForTesting();
    for (final id in ['c', 'a', 'b']) {
      await photo(id);
    }
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'legacy equal-clock photos keep their pinned order after metadata changes and reopen',
    () async {
      await repository().fetchDocuments('patient');
      expect(await order(), ['a', 'b', 'c']);
      await db.update(
        'documents',
        {'updated_at': '2099-01-01T00:00:00Z'},
        where: 'local_id = ?',
        whereArgs: ['c'],
      );
      await repository().fetchDocuments('patient');
      expect(await order(), ['a', 'b', 'c']);
      await db.close();
      db = await databaseFactoryFfi.openDatabase(
        '${directory.path}/photos.sqlite',
      );
      await repository().fetchDocuments('patient');
      expect(await order(), ['a', 'b', 'c']);
    },
  );

  test(
    'only explicit reorder moves existing photos and new photos append to their section',
    () async {
      await repository().fetchDocuments('patient');
      await repository().reorderVisitCategory(
        orderedDocumentIds: ['c', 'a', 'b'],
      );
      await photo('new', created: '2099-01-01T00:00:00Z');
      await photo('housing', tag: 'Visite - Logement');
      await repository().fetchDocuments('patient');
      expect(await order(), ['c', 'a', 'b', 'new']);
      final housing = await db.query(
        'documents',
        where: 'local_id = ?',
        whereArgs: ['housing'],
      );
      expect(housing.single['category_order'], 0);
      expect(await db.query('sync_operations'), isEmpty);
    },
  );

  test(
    'remote upload timestamps and remote ranks never replace a locally chosen order',
    () async {
      await repository().fetchDocuments('patient');
      await repository().reorderVisitCategory(
        orderedDocumentIds: ['b', 'c', 'a'],
      );
      await repository().mergeRemoteDocuments('patient', [
        for (final id in ['a', 'c', 'b'])
          {
            'id': id,
            'clientDocumentId': id,
            'title': id,
            'fileName': '$id.jpg',
            'mimeType': 'image/jpeg',
            'tags': ['Visite - Accessibilité'],
            'remotePath': '/api/mobile-documents/$id/content',
            'createdAt': '2099-01-01T00:00:00Z',
            'updatedAt': '2099-01-02T00:00:00Z',
            'categoryOrder': 0,
          },
      ]);
      await repository().fetchDocuments('patient');
      expect(await order(), ['b', 'c', 'a']);
      final rows = await db.query('documents');
      expect(rows.every((row) => row['created_at'] == timestamp), isTrue);
    },
  );

  test(
    'report receives the complete initial order even when no drag was performed',
    () async {
      final snapshot = await repository().fetchVisitReportPhotoOrder('patient');
      final byId = {
        for (final entry in snapshot) entry.localId: entry.categoryOrder,
      };
      expect(byId['a'], 0);
      expect(byId['b'], 1);
      expect(byId['c'], 2);
      expect(await order(), ['a', 'b', 'c']);
    },
  );
}
