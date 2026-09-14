import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/document_revision_store.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ObservedRevisionStore extends DocumentRevisionStore {
  ObservedRevisionStore(Directory directory, this.afterPrepare)
    : super(documentsDirectory: () async => directory);

  final Future<void> Function(File) afterPrepare;

  @override
  Future<File> prepare({
    required String extension,
    List<int>? bytes,
    File? sourceFile,
    String? annotationSourcePath,
  }) async {
    final file = await super.prepare(
      extension: extension,
      bytes: bytes,
      sourceFile: sourceFile,
      annotationSourcePath: annotationSourcePath,
    );
    await afterPrepare(file);
    return file;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late Database db;
  late File original;
  late DocumentRepository repository;
  late List<DocumentRepositoryChange> events;
  late StreamSubscription<DocumentRepositoryChange> subscription;
  final replacement = Uint8List.fromList(utf8.encode('synthetic revision two'));
  const timestamp = '2026-09-09T10:00:00.000Z';

  DocumentRepository makeRepository({DocumentRevisionStore? store}) =>
      DocumentRepository(
        database: LocalDatabase.forTesting(db),
        revisionStore:
            store ??
            DocumentRevisionStore(documentsDirectory: () async => root),
      );

  Future<void> save({DocumentRepository? using}) =>
      (using ?? repository).enqueueReplacementBytes(
        documentId: 'doc',
        bytes: replacement,
        fileName: 'devis sdb.pdf',
        mimeType: 'application/pdf',
      );

  Future<Map<String, Object?>> row() async => (await db.query(
    'documents',
    where: 'local_id = ?',
    whereArgs: ['doc'],
  )).single;

  Future<void> operation(
    String id, {
    String type = 'upload_file',
    String status = 'pending',
  }) => db
      .insert('sync_operations', {
        'id': id,
        'entity_type': 'document',
        'entity_local_id': 'doc',
        'operation_type': type,
        'status': status,
        'created_at': timestamp,
        'updated_at': timestamp,
        'payload_json': jsonEncode({'localPath': original.path}),
      })
      .then((_) {});

  setUp(() async {
    root = await Directory.systemTemp.createTemp('document-revision-test-');
    db = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'local.sqlite'),
    );
    await LocalDatabase.forTesting(db).createSchemaForTesting();
    original = await File(
      p.join(root.path, 'original.pdf'),
    ).writeAsString('original', flush: true);
    await db.insert('documents', {
      'local_id': 'doc',
      'patient_local_id': 'patient',
      'dossier_local_id': 'dossier',
      'title': 'Devis',
      'file_name': 'devis sdb.pdf',
      'file_ext': 'pdf',
      'mime_type': 'application/pdf',
      'local_file_path': original.path,
      'local_file_data_url': 'data:application/pdf;base64,b3JpZ2luYWw=',
      'remote_file_path': 'remote-old',
      'tags_json': '["Devis"]',
      'annotations_json': '{"1":"existing-overlay"}',
      'category_order': 4,
      'created_at': timestamp,
      'updated_at': timestamp,
      'sync_state': 'synced',
    });
    repository = makeRepository();
    events = [];
    subscription = DocumentRepository.changes.listen(events.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'upload acknowledgement does not invalidate an open local revision',
    () async {
      final expected = (await repository.fetchDocument('doc'))!;
      await db.update('documents', {
        'remote_public_url': 'https://example.test/acknowledged.pdf',
        'remote_file_path': 'acknowledged-upload',
        'sync_state': 'synced',
      });
      await repository.enqueueReplacementBytes(
        documentId: 'doc',
        bytes: replacement,
        fileName: 'devis.pdf',
        mimeType: 'application/pdf',
        expectedDocument: expected,
      );
      expect(
        await File((await row())['local_file_path'] as String).readAsBytes(),
        replacement,
      );
      expect(await db.query('sync_operations'), hasLength(1));
    },
  );

  test(
    'upload acknowledgement during preparation preserves the save',
    () async {
      final observed = makeRepository(
        store: ObservedRevisionStore(root, (_) async {
          await db.update('documents', {
            'remote_public_url': 'https://example.test/acknowledged.pdf',
            'remote_file_path': 'acknowledged-upload',
          });
        }),
      );
      await save(using: observed);
      expect(await db.query('sync_operations'), hasLength(1));
    },
  );

  test(
    'embedded PDF ink queues the PDF without duplicating legacy sidecars',
    () async {
      final sidecar = File('${original.path}.page1.png.annotation.json');
      await sidecar.writeAsString('legacy strokes');
      final source = await File(
        p.join(root.path, 'embedded.pdf'),
      ).writeAsString('PDF with ink');
      final expected = (await repository.fetchDocument('doc'))!;
      await repository.enqueueReplacementFile(
        documentId: 'doc',
        sourceFile: source,
        fileName: 'devis sdb.pdf',
        mimeType: 'application/pdf',
        preservePdfSidecars: false,
        expectedDocument: expected,
      );
      final current = await row();
      final newPath = current['local_file_path'] as String;
      expect(await File(newPath).readAsString(), 'PDF with ink');
      expect(
        await File('$newPath.page1.png.annotation.json').exists(),
        isFalse,
      );
      expect(current['annotations_json'], isNull);
      expect(await sidecar.readAsString(), 'legacy strokes');
      final op = (await db.query('sync_operations')).single;
      final payload = jsonDecode(op['payload_json'] as String);
      expect(payload['localPath'], newPath);
      expect(payload['mimeType'], 'application/pdf');
      expect(payload['fileName'], 'devis sdb.pdf');
      expect(op['status'], 'pending');
      expect(
        await db.query(
          'kv_store',
          where: 'key LIKE ?',
          whereArgs: ['document_previous_revision:%'],
        ),
        hasLength(1),
      );
    },
  );

  test(
    'PDF export cannot overwrite a revision changed while native work ran',
    () async {
      final expected = (await repository.fetchDocument('doc'))!;
      await save();
      final current = await row();
      await expectLater(
        repository.enqueueReplacementFile(
          documentId: 'doc',
          sourceFile: original,
          fileName: 'devis.pdf',
          mimeType: 'application/pdf',
          preservePdfSidecars: false,
          expectedDocument: expected,
        ),
        throwsStateError,
      );
      expect(await row(), current);
    },
  );

  test(
    'flattened image cannot replace content received after opening',
    () async {
      final expected = (await repository.fetchDocument('doc'))!;
      await save();
      final current = await row();
      await expectLater(
        repository.enqueueAnnotatedReuploadBytes(
          documentId: 'doc',
          bytes: replacement,
          expectedDocument: expected,
        ),
        throwsStateError,
      );
      expect(await row(), current);
    },
  );

  for (final mode in ['bytes', 'file', 'annotation bytes', 'annotation file']) {
    test(
      '$mode publishes a complete independent revision and upload together',
      () async {
        final source = await File(
          p.join(root.path, 'temporary-output'),
        ).writeAsBytes(replacement);
        switch (mode) {
          case 'bytes':
            await save();
          case 'file':
            await repository.enqueueReplacementFile(
              documentId: 'doc',
              sourceFile: source,
              fileName: 'devis sdb.pdf',
              mimeType: 'application/pdf',
            );
          case 'annotation bytes':
            await repository.enqueueAnnotatedReuploadBytes(
              documentId: 'doc',
              bytes: replacement,
            );
          case 'annotation file':
            await repository.enqueueAnnotatedReupload(
              documentId: 'doc',
              flattenedPath: source.path,
            );
        }
        await source.delete();
        final current = await row();
        final upload = (await db.query('sync_operations')).single;
        final payload = jsonDecode(upload['payload_json'] as String);
        expect(current['local_file_path'], isNot(original.path));
        expect(current['local_file_data_url'], isNull);
        expect(
          await File(current['local_file_path'] as String).readAsBytes(),
          replacement,
        );
        expect(await original.readAsString(), 'original');
        expect(payload['localPath'], current['local_file_path']);
        expect(payload['fileName'], current['file_name']);
        expect(payload['mimeType'], current['mime_type']);
        expect(payload['patientLocalId'], 'patient');
        expect(payload['documentLocalId'], 'doc');
        expect(upload['status'], 'pending');
        expect(current['sync_state'], 'pendingSync');
        expect(current['remote_file_path'], 'remote-old');
        expect(current['annotations_json'], '{"1":"existing-overlay"}');
        expect(current['category_order'], 4);
        expect(
          (await repository.fetchDocument('doc'))!.localPath,
          payload['localPath'],
        );
        await Future<void>.delayed(Duration.zero);
        expect(events.map((e) => e.documentId), ['doc']);
      },
    );
  }

  for (final failureTable in ['documents', 'sync_operations']) {
    test(
      'SQL failure on $failureTable rolls back the document and old queue',
      () async {
        await operation('old');
        final before = await row();
        final beforeQueue = await db.query('sync_operations');
        final action = failureTable == 'documents' ? 'UPDATE' : 'INSERT';
        await db.execute(
          'CREATE TRIGGER fail_save BEFORE $action ON $failureTable '
          "BEGIN SELECT RAISE(ABORT, 'synthetic disk failure'); END",
        );
        await expectLater(save(), throwsA(isA<DatabaseException>()));
        expect(await row(), before);
        expect(await db.query('sync_operations'), beforeQueue);
        expect(await original.readAsString(), 'original');
        expect(events, isEmpty);
        await db.execute('DROP TRIGGER fail_save');
        await save();
        expect((await row())['sync_state'], 'pendingSync');
      },
    );
  }

  test(
    'missing source and empty content preserve the original and queue',
    () async {
      await operation('old');
      final before = await row();
      await expectLater(
        repository.enqueueReplacementFile(
          documentId: 'doc',
          sourceFile: File(p.join(root.path, 'missing')),
          fileName: 'devis sdb.pdf',
          mimeType: 'application/pdf',
        ),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        repository.enqueueReplacementBytes(
          documentId: 'doc',
          bytes: Uint8List(0),
          fileName: 'devis sdb.pdf',
          mimeType: 'application/pdf',
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await row(), before);
      expect((await db.query('sync_operations')).single['id'], 'old');
      expect(await original.readAsString(), 'original');
      expect(
        await Directory(
          p.join(root.path, 'document_revisions'),
        ).list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'prepared but unpublished content does not alter the durable document',
    () async {
      await operation('old');
      final before = await row();
      final interrupted = makeRepository(
        store: ObservedRevisionStore(root, (_) async {
          throw const FileSystemException(
            'simulated interruption before transaction',
          );
        }),
      );
      await expectLater(
        save(using: interrupted),
        throwsA(isA<FileSystemException>()),
      );
      await db.close();
      db = await databaseFactoryFfi.openDatabase(
        p.join(root.path, 'local.sqlite'),
      );
      expect(await row(), before);
      expect((await db.query('sync_operations')).single['id'], 'old');
      expect(await original.readAsString(), 'original');
    },
  );

  test('committed offline save survives database close and reopen', () async {
    await save();
    final before = await row();
    await db.close();
    db = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'local.sqlite'),
    );
    expect(await row(), before);
    final sync = SyncRepository.forTesting(databaseProvider: () async => db);
    final queued = (await sync.fetchRunnableOperations()).single;
    expect(
      await File(
        jsonDecode(queued.payloadJson)['localPath'] as String,
      ).readAsBytes(),
      replacement,
    );
    expect(await sync.tryMarkRunning(queued), isTrue);
    await sync.markCompleted(
      operationId: queued.id,
      entityType: 'document',
      entityLocalId: 'doc',
    );
    expect((await row())['sync_state'], 'synced');
  });

  test(
    'a replacement supersedes uploads, not metadata or deletion operations',
    () async {
      await operation('old-pending');
      await operation('old-running', status: 'running');
      await operation('old-failed', status: 'failed');
      await operation('rename', type: 'update_metadata');
      await operation('delete', type: 'delete_document');
      await save();
      final queue = await db.query('sync_operations');
      expect(queue, hasLength(3));
      expect(queue.map((e) => e['id']), containsAll(['rename', 'delete']));
      final sync = SyncRepository.forTesting(databaseProvider: () async => db);
      await sync.markCompleted(
        operationId: 'old-running',
        entityType: 'document',
        entityLocalId: 'doc',
      );
      expect((await row())['sync_state'], 'pendingSync');
    },
  );

  test('an upload snapshot keeps its own bytes after a second save', () async {
    await save();
    final sync = SyncRepository.forTesting(databaseProvider: () async => db);
    final old = (await sync.fetchRunnableOperations()).single;
    expect(await sync.tryMarkRunning(old), isTrue);
    await repository.enqueueReplacementBytes(
      documentId: 'doc',
      bytes: Uint8List.fromList([1, 2, 3]),
      fileName: 'devis sdb.pdf',
      mimeType: 'application/pdf',
    );
    expect(
      await File(
        jsonDecode(old.payloadJson)['localPath'] as String,
      ).readAsBytes(),
      replacement,
    );
    await sync.storeDocumentRemoteData(
      operationId: old.id,
      documentLocalId: 'doc',
      remotePath: 'stale-result',
      publicUrl: 'stale-url',
    );
    await sync.markCompleted(
      operationId: old.id,
      entityType: 'document',
      entityLocalId: 'doc',
    );
    expect((await row())['remote_file_path'], 'remote-old');
    expect((await row())['sync_state'], 'pendingSync');
  });

  test(
    'concurrent content save cannot silently overwrite the first committed revision',
    () async {
      final prepared = Completer<void>();
      final resume = Completer<void>();
      final paused = makeRepository(
        store: ObservedRevisionStore(root, (_) async {
          prepared.complete();
          await resume.future;
        }),
      );
      final pending = save(using: paused);
      final failure = expectLater(pending, throwsStateError);
      await prepared.future;
      await save();
      final winner = await row();
      resume.complete();
      await failure;
      expect(await row(), winner);
      expect(await db.query('sync_operations'), hasLength(1));
    },
  );

  test('deletion during file preparation is not resurrected', () async {
    final paused = makeRepository(
      store: ObservedRevisionStore(root, (_) async {
        await db.update(
          'documents',
          {'pending_delete': 1},
          where: 'local_id = ?',
          whereArgs: ['doc'],
        );
      }),
    );
    await expectLater(save(using: paused), throwsStateError);
    expect((await row())['pending_delete'], 1);
    expect((await row())['local_file_path'], original.path);
    expect(await db.query('sync_operations'), isEmpty);
    expect(await repository.fetchDocument('doc'), isNull);
  });

  test(
    'PDF bytes publication archives legacy overlays and queues the complete PDF',
    () async {
      const overlays = '{"1":"legacy-page-one","3":"legacy-page-three"}';
      await db.update('documents', {'annotations_json': overlays});
      final expected = (await repository.fetchDocument('doc'))!;
      await repository.enqueueReplacementBytes(
        documentId: 'doc',
        bytes: replacement,
        fileName: 'devis sdb.pdf',
        mimeType: 'application/pdf',
        preservePdfSidecars: false,
        expectedDocument: expected,
      );
      expect((await row())['annotations_json'], isNull);
      expect((await row())['sync_state'], 'pendingSync');
      final backups = await db.query(
        'kv_store',
        where: 'key LIKE ?',
        whereArgs: ['document_previous_revision:doc:%'],
      );
      expect(
        jsonDecode(backups.single['value'] as String)['annotations_json'],
        overlays,
      );
      final payload = jsonDecode(
        (await db.query('sync_operations')).single['payload_json'] as String,
      );
      expect(payload['mimeType'], 'application/pdf');
      expect(payload['fileName'], 'devis sdb.pdf');
      expect(
        await File(payload['localPath'] as String).readAsBytes(),
        replacement,
      );
    },
  );

  test(
    'a legacy annotation change during export rejects stale PDF bytes',
    () async {
      final expected = (await repository.fetchDocument('doc'))!;
      await db.update('documents', {'annotations_json': '{"2":"newer"}'});
      await expectLater(
        repository.enqueueReplacementBytes(
          documentId: 'doc',
          bytes: replacement,
          fileName: 'devis sdb.pdf',
          mimeType: 'application/pdf',
          preservePdfSidecars: false,
          expectedDocument: expected,
        ),
        throwsStateError,
      );
      expect((await row())['annotations_json'], '{"2":"newer"}');
      expect(await db.query('sync_operations'), isEmpty);
    },
  );

  test(
    'annotation change during file preparation also rejects a stale conversion',
    () async {
      final paused = makeRepository(
        store: ObservedRevisionStore(root, (_) async {
          await db.update('documents', {
            'annotations_json': '{"2":"concurrent"}',
          });
        }),
      );
      await expectLater(
        paused.enqueueReplacementBytes(
          documentId: 'doc',
          bytes: replacement,
          fileName: 'devis sdb.pdf',
          mimeType: 'application/pdf',
          preservePdfSidecars: false,
        ),
        throwsStateError,
      );
      expect((await row())['annotations_json'], '{"2":"concurrent"}');
      expect((await row())['local_file_path'], original.path);
      expect(await db.query('sync_operations'), isEmpty);
    },
  );

  test(
    'queue failure retains legacy overlays and original bytes, retry succeeds',
    () async {
      const overlays = '{"1":"keep-me"}';
      await db.update('documents', {'annotations_json': overlays});
      await db.execute(
        "CREATE TRIGGER fail_web_pdf BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'failure'); END",
      );
      Future<void> publish() => repository.enqueueReplacementBytes(
        documentId: 'doc',
        bytes: replacement,
        fileName: 'devis sdb.pdf',
        mimeType: 'application/pdf',
        preservePdfSidecars: false,
      );
      await expectLater(publish(), throwsA(isA<DatabaseException>()));
      expect((await row())['annotations_json'], overlays);
      expect((await row())['local_file_path'], original.path);
      expect(
        await db.query(
          'kv_store',
          where: 'key LIKE ?',
          whereArgs: ['document_previous_revision:doc:%'],
        ),
        isEmpty,
      );
      await db.execute('DROP TRIGGER fail_web_pdf');
      await publish();
      expect((await row())['annotations_json'], isNull);
      expect(await db.query('sync_operations'), hasLength(1));
    },
  );

  test(
    'metadata changed during preparation is preserved in the new upload',
    () async {
      final paused = makeRepository(
        store: ObservedRevisionStore(root, (_) async {
          await db.update(
            'documents',
            {'title': 'Renamed', 'tags_json': '["Autre"]'},
            where: 'local_id = ?',
            whereArgs: ['doc'],
          );
        }),
      );
      await save(using: paused);
      final upload = (await db.query('sync_operations')).single;
      final payload = jsonDecode(upload['payload_json'] as String);
      expect(payload['title'], 'Renamed');
      expect(payload['tags'], ['Autre']);
      expect((await row())['title'], 'Renamed');
    },
  );

  test(
    'PDF sidecars follow a revision but rendered pages and other documents do not',
    () async {
      final annotation = await File(
        '${original.path}.page2.png.annotation.json',
      ).writeAsString('[{"stroke":1}]');
      await File(
        '${original.path}.page2.png',
      ).writeAsString('rendered preview');
      await File(
        '${original.path}.other.page2.png.annotation.json',
      ).writeAsString('unrelated');
      await save();
      final path = (await row())['local_file_path'] as String;
      expect(
        await File('$path.page2.png.annotation.json').readAsString(),
        await annotation.readAsString(),
      );
      expect(await File('$path.page2.png').exists(), isFalse);
      expect(
        await File('$path.other.page2.png.annotation.json').exists(),
        isFalse,
      );
    },
  );

  test(
    'a missing document fails instead of reporting a successful save',
    () async {
      await db.delete('documents');
      await expectLater(save(), throwsStateError);
      expect(await db.query('sync_operations'), isEmpty);
      expect(events, isEmpty);
    },
  );

  test(
    'an unwritable revision location does not touch the previous file',
    () async {
      final blocked = await File(
        p.join(root.path, 'not-a-directory'),
      ).writeAsString('keep');
      final failing = makeRepository(
        store: DocumentRevisionStore(
          documentsDirectory: () async => Directory(blocked.path),
        ),
      );
      final before = await row();
      await expectLater(
        save(using: failing),
        throwsA(isA<FileSystemException>()),
      );
      expect(await row(), before);
      expect(await original.readAsString(), 'original');
      expect(await blocked.readAsString(), 'keep');
      expect(await db.query('sync_operations'), isEmpty);
    },
  );
}
