import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aid_habitat_app/components/doc_thumbnails.dart';
import 'package:aid_habitat_app/services/document_repository.dart';
import 'package:aid_habitat_app/services/document_revision_store.dart';
import 'package:aid_habitat_app/services/document_upload_identity.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory root;
  late Database db;
  late File original;
  late DocumentRepository repository;
  const first = '2026-09-09T10:00:00.000Z';
  const second = '2026-09-09T11:00:00.000Z';
  const third = '2026-09-09T12:00:00.000Z';
  String url(String version) => '/api/mobile-documents/$version/content';

  DocumentRepository makeRepository({
    Future<File?> Function(String)? fetcher,
  }) => DocumentRepository(
    database: LocalDatabase.forTesting(db),
    revisionStore: DocumentRevisionStore(documentsDirectory: () async => root),
    remoteFileFetcher: fetcher,
    prefetchRemoteAssets: false,
  );

  Map<String, dynamic> remote({
    String revision = 'v2',
    String? timestamp = second,
    String title = 'New title',
  }) => {
    'clientDocumentId': 'doc',
    'remotePath': url(revision),
    'publicUrl': url(revision),
    'fileName': 'devis.pdf',
    'mimeType': 'application/pdf',
    'title': title,
    'tags': ['Devis'],
    if (timestamp != null) 'updatedAt': timestamp,
  };

  Future<Map<String, Object?>> row() async => (await db.query(
    'documents',
    where: 'local_id = ?',
    whereArgs: ['doc'],
  )).single;

  Future<void> operation(String status, {String type = 'upload_file'}) async {
    await db.insert('sync_operations', {
      'id': 'op',
      'entity_type': 'document',
      'entity_local_id': 'doc',
      'operation_type': type,
      'status': status,
      'created_at': first,
      'updated_at': first,
      'payload_json': '{}',
    });
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('remote-revision-test-');
    db = await databaseFactoryFfi.openDatabase(
      p.join(root.path, 'local.sqlite'),
    );
    await LocalDatabase.forTesting(db).createSchemaForTesting();
    original = await File(
      p.join(root.path, 'old.pdf'),
    ).writeAsString('old bytes');
    await db.insert('documents', {
      'local_id': 'doc',
      'patient_local_id': 'patient',
      'dossier_local_id': 'dossier',
      'organisation_id': 'org-test',
      'title': 'Old title',
      'file_name': 'devis.pdf',
      'file_ext': 'pdf',
      'mime_type': 'application/pdf',
      'local_file_path': original.path,
      'local_file_data_url': 'data:application/pdf;base64,b2xk',
      'remote_file_path': url('v1'),
      'remote_public_url': url('v1'),
      'annotations_json': '{"1":"old overlay"}',
      'tags_json': '["Devis"]',
      'category_order': 4,
      'sync_state': 'synced',
      'created_at': first,
      'updated_at': first,
    });
    repository = makeRepository();
  });

  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('a newer remote document cannot replace unsent local content', () async {
    await db.update('documents', {
      'title': 'Titre local fictif', 'sync_state': 'pendingSync',
    });
    await repository.mergeRemoteDocuments('patient', [
      remote(revision: 'v2', timestamp: third),
    ]);
    expect((await row())['title'], 'Titre local fictif');
    expect((await row())['remote_file_path'], url('v1'));
    expect((await row())['sync_state'], 'pendingSync');
  });

  for (final state in ['synced', 'pendingSync', 'error']) {
    test(
      'delete remotely bound document in $state enqueues remote delete',
      () async {
        await db.update('documents', {'sync_state': state});
        await repository.deleteDocument('doc');
        expect((await row())['pending_delete'], 1);
        final queued = await db.query('sync_operations');
        expect(queued.single['operation_type'], 'delete_document');
        await repository.mergeRemoteDocuments('patient', [
          remote(revision: 'v1'),
        ]);
        expect((await row())['pending_delete'], 1);
      },
    );
  }

  test(
    'running replacement remains tracked and delete uses stable client id',
    () async {
      await operation('running');
      await repository.deleteDocument('doc');
      final queued = await db.query('sync_operations');
      expect(
        queued.where((op) => op['operation_type'] == 'upload_file'),
        hasLength(1),
      );
      final deletion = queued.singleWhere(
        (op) => op['operation_type'] == 'delete_document',
      );
      final payload = jsonDecode(
        await OfflineVault.instance.openString(
          deletion['payload_json'] as String,
        ),
      );
      expect(payload['remoteDocumentId'], 'doc');
      expect((await row())['pending_delete'], 1);
    },
  );

  test(
    'first upload in flight also queues deletion instead of discarding tracking',
    () async {
      await db.update('documents', {
        'remote_file_path': null,
        'remote_public_url': null,
        'sync_state': 'pendingSync',
      });
      await operation('running');
      await repository.deleteDocument('doc');
      expect((await row())['pending_delete'], 1);
      expect((await db.query('sync_operations')).length, 2);
    },
  );

  test(
    'stale listing cannot resurrect deleted document after local purge',
    () async {
      await repository.deleteDocument('doc');
      await db.delete('documents');
      await db.delete('sync_operations');
      repository = makeRepository();
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v1'),
      ]);
      expect(await db.query('documents'), isEmpty);
      // A delayed replacement path with the same client identity is also stale.
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v2'),
      ]);
      expect(await db.query('documents'), isEmpty);
    },
  );

  test('deletion does not hide a new document with the same title', () async {
    await repository.deleteDocument('doc');
    await db.delete('documents');
    await db.delete('sync_operations');
    await repository.mergeRemoteDocuments('patient', [
      {...remote(revision: 'v3'), 'clientDocumentId': 'new-document'},
    ]);
    expect((await db.query('documents')).single['pending_delete'], 0);
  });

  test('deletion identities are scoped to their patient', () async {
    await repository.deleteDocument('doc');
    await repository.mergeRemoteDocuments('other-patient', [
      remote(revision: 'v1'),
    ]);
    expect(
      (await db.query(
        'documents',
        where: 'patient_local_id = ?',
        whereArgs: ['other-patient'],
      )),
      hasLength(1),
    );
  });

  test(
    'new remote UUID detaches stale bytes and overlays, retaining a recovery snapshot',
    () async {
      await repository.mergeRemoteDocuments('patient', [remote()]);
      final current = await row();
      expect(current['local_file_path'], isNull);
      expect(current['local_file_data_url'], isNull);
      expect(current['annotations_json'], isNull);
      expect(current['remote_public_url'], url('v2'));
      expect(current['dossier_local_id'], 'dossier');
      expect(current['organisation_id'], 'org-test');
      expect(current['category_order'], 4);
      expect(await original.readAsString(), 'old bytes');
      final backups = await db.query(
        'kv_store',
        where: 'key LIKE ?',
        whereArgs: ['document_previous_revision:%'],
      );
      final snapshot = jsonDecode(backups.single['value'] as String);
      expect(snapshot['annotations_json'], '{"1":"old overlay"}');
      expect(snapshot['local_file_path'], original.path);
      expect(
        snapshot['local_file_data_url'],
        'data:application/pdf;base64,b2xk',
      );
    },
  );

  test(
    'rename keeps local bytes and annotations and does not download',
    () async {
      var downloads = 0;
      repository = makeRepository(
        fetcher: (_) async {
          downloads++;
          return null;
        },
      );
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v1'),
      ]);
      await repository.prefetchDocumentAssets('patient');
      final current = await row();
      expect(current['title'], 'New title');
      expect(current['local_file_path'], original.path);
      expect(current['annotations_json'], '{"1":"old overlay"}');
      expect(downloads, 0);
      expect(
        await db.query(
          'kv_store',
          where: 'key LIKE ?',
          whereArgs: ['document_previous_revision:%'],
        ),
        isEmpty,
      );
    },
  );

  test('missing remote timestamp does not churn visual cache keys', () async {
    final incoming = remote(revision: 'v1', timestamp: null);
    await repository.mergeRemoteDocuments('patient', [incoming]);
    final before = documentVisualCacheKey(
      (await repository.fetchDocument('doc'))!,
    );
    await repository.mergeRemoteDocuments('patient', [incoming]);
    expect(
      documentVisualCacheKey((await repository.fetchDocument('doc'))!),
      before,
    );
    expect((await row())['updated_at'], first);
  });

  for (final status in ['pending', 'running', 'failed', 'conflict']) {
    test(
      '$status operation protects local content despite synced flag and newer remote clock',
      () async {
        await operation(status);
        final before = await row();
        await repository.mergeRemoteDocuments('patient', [
          remote(timestamp: third),
        ]);
        expect(await row(), before);
        expect((await db.query('sync_operations')).single['status'], status);
      },
    );
  }

  test('pending metadata is protected just like pending content', () async {
    await operation('pending', type: 'update_document_metadata');
    final before = await row();
    await repository.mergeRemoteDocuments('patient', [remote()]);
    expect(await row(), before);
  });

  test('completed operation does not block remote content', () async {
    await operation('completed');
    await repository.mergeRemoteDocuments('patient', [remote()]);
    expect((await row())['local_file_path'], isNull);
  });

  test('pending deletion is never resurrected', () async {
    await db.update(
      'documents',
      {'pending_delete': 1},
      where: 'local_id = ?',
      whereArgs: ['doc'],
    );
    final before = await row();
    await repository.mergeRemoteDocuments('patient', [remote()]);
    expect(await row(), before);
  });

  test(
    'pending operations also protect documents absent from reconciliation',
    () async {
      await operation('pending');
      await repository.mergeRemoteDocuments('patient', [
        {
          ...remote(),
          'clientDocumentId': 'other',
          'remotePath': url('other'),
          'publicUrl': url('other'),
        },
      ]);
      expect((await row())['local_file_path'], original.path);
    },
  );

  test(
    'late older pull cannot roll back an accepted server revision',
    () async {
      await repository.mergeRemoteDocuments('patient', [remote()]);
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v1', timestamp: first),
      ]);
      expect((await row())['remote_file_path'], url('v2'));
      expect((await row())['updated_at'], second);
    },
  );

  test(
    'device clock ahead does not reject a synced remote replacement',
    () async {
      await db.update(
        'documents',
        {'updated_at': '2030-01-01T00:00:00Z'},
        where: 'local_id = ?',
        whereArgs: ['doc'],
      );
      await repository.mergeRemoteDocuments('patient', [remote()]);
      expect((await row())['remote_file_path'], url('v2'));
    },
  );

  test(
    'old pull cannot undo a newer upload binding after acknowledgement',
    () async {
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v1', timestamp: first),
      ]);
      await db.update(
        'documents',
        {'remote_file_path': url('v2'), 'remote_public_url': url('v2')},
        where: 'local_id = ?',
        whereArgs: ['doc'],
      );
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v1', timestamp: first),
      ]);
      expect((await row())['remote_file_path'], url('v2'));
    },
  );

  for (final timestamp in [null, first, third]) {
    test(
      'acknowledged upload rejects superseded content ($timestamp)',
      () async {
        await operation('running');
        final sync = SyncRepository.forTesting(
          databaseProvider: () async => db,
        );
        await sync.storeDocumentRemoteData(
          operationId: 'op',
          documentLocalId: 'doc',
          remotePath: url('v2'),
          publicUrl: url('v2'),
        );
        await sync.markCompleted(
          operationId: 'op',
          entityType: 'document',
          entityLocalId: 'doc',
        );
        repository = makeRepository();
        // No prior pull/version marker, as with an imported document.
        await repository.mergeRemoteDocuments('patient', [
          remote(revision: 'v1', timestamp: timestamp),
        ]);
        expect((await row())['remote_file_path'], url('v2'));
        expect((await row())['local_file_path'], original.path);
        expect((await row())['sync_state'], 'synced');
        // A genuinely new immutable content path must still be accepted.
        await repository.mergeRemoteDocuments('patient', [
          remote(revision: 'v3', timestamp: third),
        ]);
        expect((await row())['remote_file_path'], url('v3'));
      },
    );
  }

  test(
    'upload binding rolls back when retired marker cannot be stored',
    () async {
      await operation('running');
      await db.execute("""
      CREATE TRIGGER reject_retired BEFORE INSERT ON kv_store
      WHEN NEW.key LIKE 'document_retired_content:%'
      BEGIN SELECT RAISE(ABORT, 'injected storage failure'); END
    """);
      final sync = SyncRepository.forTesting(databaseProvider: () async => db);
      await expectLater(
        sync.storeDocumentRemoteData(
          operationId: 'op',
          documentLocalId: 'doc',
          remotePath: url('v2'),
          publicUrl: url('v2'),
        ),
        throwsA(isA<DatabaseException>()),
      );
      expect((await row())['remote_file_path'], url('v1'));
      expect((await db.query('sync_operations')).single['status'], 'running');
    },
  );

  test(
    'native download uses the same versioned URL as thumbnail and opens new bytes',
    () async {
      final requested = <String>[];
      final downloaded = await File(
        p.join(root.path, 'download'),
      ).writeAsString('new bytes');
      repository = makeRepository(
        fetcher: (url) async {
          requested.add(url);
          return downloaded;
        },
      );
      await repository.mergeRemoteDocuments('patient', [remote()]);
      final expected = documentPreviewUrl(
        (await repository.fetchDocument('doc'))!,
      );
      await repository.prefetchDocumentAssets('patient');
      final path = (await row())['local_file_path'] as String;
      expect(path, isNot(original.path));
      expect(path, isNot(downloaded.path));
      expect(await File(path).readAsString(), 'new bytes');
      expect(requested, [expected]);
      await repository.prefetchDocumentAssets('patient');
      expect(requested, hasLength(1));
    },
  );

  test('offline download can retry without attaching old bytes', () async {
    final downloaded = await File(
      p.join(root.path, 'download'),
    ).writeAsString('new bytes');
    var online = false;
    repository = makeRepository(
      fetcher: (_) async => online ? downloaded : null,
    );
    await repository.mergeRemoteDocuments('patient', [remote()]);
    await repository.prefetchDocumentAssets('patient');
    expect((await row())['local_file_path'], isNull);
    online = true;
    await repository.prefetchDocumentAssets('patient');
    expect(
      await File((await row())['local_file_path'] as String).readAsString(),
      'new bytes',
    );
  });

  test(
    'late download cannot attach itself to a newer remote revision',
    () async {
      final started = Completer<void>();
      final result = Completer<File?>();
      repository = makeRepository(
        fetcher: (_) {
          started.complete();
          return result.future;
        },
      );
      await repository.mergeRemoteDocuments('patient', [remote()]);
      final pending = repository.prefetchDocumentAssets('patient');
      await started.future;
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v3', timestamp: third),
      ]);
      result.complete(
        await File(p.join(root.path, 'download')).writeAsString('v2 bytes'),
      );
      await pending;
      expect((await row())['remote_file_path'], url('v3'));
      expect((await row())['local_file_path'], isNull);
      final revisions = Directory(p.join(root.path, 'document_revisions'));
      expect(await revisions.list().toList(), isEmpty);
    },
  );

  test('late download cannot overwrite a new local offline save', () async {
    final started = Completer<void>();
    final result = Completer<File?>();
    repository = makeRepository(
      fetcher: (_) {
        started.complete();
        return result.future;
      },
    );
    await repository.mergeRemoteDocuments('patient', [remote()]);
    final pending = repository.prefetchDocumentAssets('patient');
    await started.future;
    await repository.enqueueReplacementBytes(
      documentId: 'doc',
      bytes: Uint8List.fromList(utf8.encode('offline rotation')),
      fileName: 'devis.pdf',
      mimeType: 'application/pdf',
    );
    final saved = await row();
    result.complete(
      await File(p.join(root.path, 'download')).writeAsString('v2 bytes'),
    );
    await pending;
    expect(await row(), saved);
    expect((await db.query('sync_operations')).single['status'], 'pending');
    expect(
      await File(saved['local_file_path'] as String).readAsString(),
      'offline rotation',
    );
  });

  test(
    'foreground cache hydration is guarded against stale revision and deletion',
    () async {
      await repository.mergeRemoteDocuments('patient', [remote()]);
      final expected = (await repository.fetchDocument('doc'))!;
      await repository.mergeRemoteDocuments('patient', [
        remote(revision: 'v3', timestamp: third),
      ]);
      expect(
        await repository.storeLocalDocumentPath(
          expectedDocument: expected,
          localFilePath: original.path,
        ),
        isFalse,
      );
      final latest = (await repository.fetchDocument('doc'))!;
      await db.update(
        'documents',
        {'pending_delete': 1},
        where: 'local_id = ?',
        whereArgs: ['doc'],
      );
      expect(
        await repository.storeLocalDocumentPath(
          expectedDocument: latest,
          localFilePath: original.path,
        ),
        isFalse,
      );
    },
  );

  test(
    'a missing local cache file is replaced even when its path is nonempty',
    () async {
      await db.update(
        'documents',
        {
          'local_file_path': p.join(root.path, 'missing.pdf'),
          'local_file_data_url': null,
        },
        where: 'local_id = ?',
        whereArgs: ['doc'],
      );
      final downloaded = await File(
        p.join(root.path, 'download'),
      ).writeAsString('restored');
      repository = makeRepository(fetcher: (_) async => downloaded);
      await repository.prefetchDocumentAssets('patient');
      expect(
        await File((await row())['local_file_path'] as String).readAsString(),
        'restored',
      );
    },
  );

  test('failure to preserve old revision rolls back merge', () async {
    await db.execute("""
      CREATE TRIGGER reject_backup BEFORE INSERT ON kv_store
      WHEN NEW.key LIKE 'document_previous_revision:%'
      BEGIN SELECT RAISE(ABORT, 'synthetic full disk'); END
    """);
    final before = await row();
    await expectLater(
      repository.mergeRemoteDocuments('patient', [remote()]),
      throwsA(anything),
    );
    expect(await row(), before);
  });

  test('successive replacements keep both recovery snapshots', () async {
    await repository.mergeRemoteDocuments('patient', [remote()]);
    await repository.mergeRemoteDocuments('patient', [
      remote(revision: 'v3', timestamp: third),
    ]);
    final backups = await db.query(
      'kv_store',
      where: 'key LIKE ?',
      whereArgs: ['document_previous_revision:%'],
    );
    expect(backups, hasLength(2));
    expect(
      backups.map(
        (row) => jsonDecode(row['value'] as String)['remote_file_path'],
      ),
      containsAll([url('v1'), url('v2')]),
    );
  });

  test(
    'first remote binding does not invalidate an uploaded local original',
    () async {
      await db.update(
        'documents',
        {'remote_file_path': '', 'remote_public_url': null},
        where: 'local_id = ?',
        whereArgs: ['doc'],
      );
      await repository.mergeRemoteDocuments('patient', [remote()]);
      expect((await row())['local_file_path'], original.path);
      expect((await row())['annotations_json'], '{"1":"old overlay"}');
    },
  );

  test(
    'one content update leaves other document visual cache keys unchanged',
    () async {
      await db.insert('documents', {
        ...await row(),
        'local_id': 'untouched',
        'remote_file_path': url('untouched'),
        'remote_public_url': url('untouched'),
      });
      final before = documentVisualCacheKey(
        (await repository.fetchDocument('untouched'))!,
      );
      await repository.mergeRemoteDocuments('patient', [
        remote(),
        {
          ...remote(
            revision: 'untouched',
            timestamp: first,
            title: 'Old title',
          ),
          'clientDocumentId': 'untouched',
        },
      ]);
      expect(
        documentVisualCacheKey((await repository.fetchDocument('untouched'))!),
        before,
      );
    },
  );

  test(
    'same client id in a different patient cannot alter this patient',
    () async {
      final before = await row();
      await repository.mergeRemoteDocuments('another-patient', [remote()]);
      expect(await row(), before);
    },
  );

  test(
    'imported report retains its server identity across replacement and restart',
    () async {
      await db.delete('documents');
      final imported = {
        ...remote(revision: 'report-before'),
        'id': 'report-before',
        'clientDocumentId': 'report-origin-client',
      };
      await repository.mergeRemoteDocuments('patient', [imported]);
      final opened = (await repository.fetchDocuments('patient')).single;
      expect(opened.id, isNot('report-origin-client'));
      expect(
        await readDocumentUploadIdentity(db, 'patient', opened.id),
        'report-origin-client',
      );
      expect(
        resolveImportedDocumentUploadIdentity([imported], [opened.url!]),
        'report-origin-client',
      );
      repository = makeRepository();
      await repository.mergeRemoteDocuments('patient', [
        {
          ...imported,
          'id': 'report-after',
          'remotePath': url('report-after'),
          'publicUrl': url('report-after'),
          'updatedAt': third,
        },
      ]);
      final reopened = (await repository.fetchDocuments('patient')).single;
      expect(reopened.id, opened.id);
      expect(reopened.url, url('report-after'));
      expect(
        await readDocumentUploadIdentity(db, 'another-patient', opened.id),
        isNull,
      );
    },
  );

  test('imported replacement refuses missing or ambiguous identity', () {
    final document = {...remote(), 'clientDocumentId': 'origin'};
    expect(
      () => resolveImportedDocumentUploadIdentity(
        [{'clientDocumentId': 'unrelated'}],
        ['https://example.invalid'],
      ),
      throwsStateError,
    );
    expect(
      () => resolveImportedDocumentUploadIdentity([], [url('v2')]),
      throwsStateError,
    );
    expect(
      () => resolveImportedDocumentUploadIdentity(
        [document, document],
        [url('v2')],
      ),
      throwsStateError,
    );
    expect(
      () => resolveImportedDocumentUploadIdentity(
        [
          {...document, 'clientDocumentId': ''},
        ],
        [url('v2')],
      ),
      throwsStateError,
    );
  });

  test(
    'stale imported report cannot reappear after replacement acknowledgement',
    () async {
      await db.delete('documents');
      final imported = {
        ...remote(revision: 'before'),
        'id': 'before',
        'clientDocumentId': 'original-client',
      };
      await repository.mergeRemoteDocuments('patient', [imported]);
      final opened = (await repository.fetchDocuments('patient')).single;
      final saved = await repository.enqueueReplacementBytes(
        documentId: opened.id,
        bytes: Uint8List.fromList('rotated report'.codeUnits),
        fileName: 'report.pdf',
        mimeType: 'application/pdf',
      );
      final operation = (await db.query('sync_operations')).single;
      await db.update(
        'sync_operations',
        {'status': 'running'},
        where: 'id = ?',
        whereArgs: [operation['id']],
      );
      await SyncRepository.forTesting(
        database: LocalDatabase.forTesting(db),
      ).storeDocumentRemoteData(
        operationId: operation['id'] as String,
        documentLocalId: opened.id,
        remotePath: url('after'),
        publicUrl: url('after'),
      );
      await db.update(
        'sync_operations',
        {'status': 'completed'},
        where: 'id = ?',
        whereArgs: [operation['id']],
      );
      await db.update(
        'documents',
        {'sync_state': 'synced'},
        where: 'local_id = ?',
        whereArgs: [opened.id],
      );
      repository = makeRepository();
      await repository.mergeRemoteDocuments('patient', [imported]);
      final reopened = (await repository.fetchDocuments('patient')).single;
      expect(reopened.id, opened.id);
      expect(reopened.url, url('after'));
      expect(reopened.localPath, saved.localPath);
      expect(await File(reopened.localPath!).readAsString(), 'rotated report');
    },
  );
}
