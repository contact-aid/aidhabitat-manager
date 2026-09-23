import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late SyncRepository repository;
  final timestamp = DateTime(2026, 9, 9).toIso8601String();

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE kv_store (
        key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE sync_operations (
        id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
        entity_local_id TEXT NOT NULL, operation_type TEXT NOT NULL,
        payload_json TEXT NOT NULL, status TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0, last_error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE documents (
        local_id TEXT PRIMARY KEY, sync_state TEXT NOT NULL,
        dossier_local_id TEXT, patient_local_id TEXT,
        pending_delete INTEGER NOT NULL DEFAULT 0,
        remote_file_path TEXT, remote_public_url TEXT, updated_at TEXT
      )
    ''');
    for (final table in ['note_pages', 'patients', 'housings']) {
      await db.execute(
        'CREATE TABLE $table ('
        'local_id TEXT PRIMARY KEY, sync_state TEXT NOT NULL, remote_updated_at TEXT)',
      );
    }
    await db.execute('ALTER TABLE housings ADD COLUMN remote_housing_id TEXT');
    await db.execute('ALTER TABLE note_pages ADD COLUMN dossier_local_id TEXT');
    await db.execute('ALTER TABLE note_pages ADD COLUMN patient_local_id TEXT');
    await db.execute('ALTER TABLE note_pages ADD COLUMN remote_revision TEXT');
    await db.execute(
      'ALTER TABLE note_pages ADD COLUMN drawing_remote_path TEXT',
    );
    await db.execute(
      'ALTER TABLE note_pages ADD COLUMN drawing_remote_url TEXT',
    );
    await db.execute(
      'CREATE TABLE dossiers (local_id TEXT PRIMARY KEY, '
      'housing_local_id TEXT, patient_local_id TEXT, sync_state TEXT, remote_updated_at TEXT)',
    );
    await db.insert('documents', {
      'local_id': 'doc-1',
      'sync_state': 'pendingSync',
      'remote_file_path': 'old-path',
      'remote_public_url': 'old-url',
      'updated_at': timestamp,
    });
    repository = SyncRepository.forTesting(databaseProvider: () async => db);
  });

  tearDown(() async => db.close());

  Future<void> insertOperation(
    String id, {
    String status = 'pending',
    String entityType = 'document',
    String entityId = 'doc-1',
    String operationType = 'upload_file',
    String payload = '{"localPath":"revision-1.pdf"}',
  }) async {
    await db.insert('sync_operations', {
      'id': id,
      'entity_type': entityType,
      'entity_local_id': entityId,
      'operation_type': operationType,
      'payload_json': payload,
      'status': status,
      'created_at': timestamp,
      'updated_at': timestamp,
    });
  }

  test('details include conflicts and retry/discard preserve them', () async {
    await insertOperation('conflict', status: 'conflict');
    await insertOperation('failed', status: 'failed');
    await insertOperation('pending');
    final details = await repository.fetchAllFailingOperations();
    expect(
      details.map((op) => op['status']),
      unorderedEquals(['failed', 'conflict']),
    );
    final before = await db.query(
      'sync_operations',
      where: 'id = ?',
      whereArgs: ['conflict'],
    );
    expect(await repository.resetSingleOperationToPending('conflict'), 0);
    expect(await repository.discardSingleOperation('conflict'), 0);
    expect(await repository.resetFailedToPending(), 1);
    expect(
      await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: ['conflict'],
      ),
      before,
    );
  });

  test('conflict navigation refuses ambiguous dossier bindings', () async {
    await db.insert('dossiers', {'local_id': 'd1', 'patient_local_id': 'p1'});
    await insertOperation(
      'c',
      status: 'conflict',
      entityType: 'patient',
      entityId: 'p1',
    );
    expect(await repository.conflictDossierId('c'), 'd1');
    await db.insert('dossiers', {'local_id': 'd2', 'patient_local_id': 'p1'});
    expect(await repository.conflictDossierId('c'), isNull);
    expect(await repository.conflictDossierId('missing'), isNull);
  });

  test(
    'a housing conflict resolves to the dossier, not the housing row',
    () async {
      // Housing operations are enqueued with the dossier's own local_id as
      // entity_local_id (unlike 'patient', which uses the patient's own
      // local_id) — cf. `_enqueueEntityUpdate(entityType: 'housing',
      // entityLocalId: dossierId, ...)` in dossier_repository.dart. A
      // review must key off that same id, not the housing row's local_id,
      // or it can never find the dossier (regression covered here after
      // it shipped broken: "Comparaison indisponible" for every housing
      // conflict, reported 2026-09-22).
      await db.insert('dossiers', {
        'local_id': 'd1',
        'housing_local_id': 'housing-local',
      });
      await insertOperation(
        'h',
        status: 'conflict',
        entityType: 'housing',
        entityId: 'd1',
      );
      expect(await repository.conflictDossierId('h'), 'd1');
    },
  );

  test('housing ACK stores remote identity and version atomically', () async {
    await db.insert('housings', {
      'local_id': 'housing-local',
      'sync_state': 'pendingSync',
    });
    await db.insert('dossiers', {
      'local_id': 'd1',
      'housing_local_id': 'housing-local',
      'sync_state': 'pendingSync',
    });
    const payload = '{"updates":{"surface":80}}';
    await insertOperation(
      'housing-op',
      status: 'running',
      entityType: 'housing',
      entityId: 'd1',
      operationType: 'update',
      payload: payload,
    );
    final operation = SyncOperation(
      id: 'housing-op',
      entityType: 'housing',
      entityLocalId: 'd1',
      operationType: 'update',
      payloadJson: payload,
      status: SyncOperationStatus.running,
      attemptCount: 0,
      createdAt: DateTime.parse(timestamp),
      updatedAt: DateTime.parse(timestamp),
    );
    expect(
      await repository.acknowledgeVersionedMutation(
        operation,
        '2026-09-10T10:00:00.000Z',
        remoteEntityId: 'housing-remote',
      ),
      isTrue,
    );
    final housing = (await db.query('housings')).single;
    expect(housing['remote_housing_id'], 'housing-remote');
    expect(housing['remote_updated_at'], '2026-09-10T10:00:00.000Z');
    expect(housing['sync_state'], 'synced');
  });

  test(
    'note ACK rebases a rapid successor without losing its content',
    () async {
      const oldRevision = '00000000-0000-4000-8000-000000000000';
      const firstWrite = '11111111-1111-4111-8111-111111111111';
      const secondWrite = '22222222-2222-4222-8222-222222222222';
      const acknowledged = '33333333-3333-4333-8333-333333333333';
      await db.insert('note_pages', {
        'local_id': 'note-1',
        'sync_state': 'pendingSync',
        'remote_revision': oldRevision,
      });
      final sent = {
        'patientLocalId': 'patient-1',
        'tabKey': 'Contexte de vie-Médical',
        'pageNumber': 0,
        'drawingJson': 'first',
        'expectedRevision': oldRevision,
        'writeId': firstWrite,
        'predecessorWriteIds': <String>[],
      };
      final pending = {
        ...sent,
        'drawingJson': 'latest',
        'writeId': secondWrite,
        'predecessorWriteIds': [firstWrite],
      };
      await insertOperation(
        'note-op',
        status: 'pending',
        entityType: 'note_page',
        entityId: 'note-1',
        operationType: 'upsert',
        payload: jsonEncode(pending),
      );
      final operation = SyncOperation(
        id: 'note-op',
        entityType: 'note_page',
        entityLocalId: 'note-1',
        operationType: 'upsert',
        payloadJson: jsonEncode(sent),
        status: SyncOperationStatus.running,
        attemptCount: 0,
        createdAt: DateTime.parse(timestamp),
        updatedAt: DateTime.parse(timestamp),
      );

      expect(
        await repository.acknowledgeNotePageMutation(
          operation,
          revision: acknowledged,
          remotePath: 'remote/path',
          remoteUrl: 'https://example.test/note',
        ),
        isFalse,
      );

      final queued = (await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: ['note-op'],
      )).single;
      final payload = jsonDecode(queued['payload_json'] as String) as Map;
      expect(queued['status'], 'pending');
      expect(payload['drawingJson'], 'latest');
      expect(payload['writeId'], secondWrite);
      expect(payload['expectedRevision'], acknowledged);
      final note = (await db.query('note_pages')).single;
      expect(note['remote_revision'], acknowledged);
      expect(note['drawing_remote_path'], 'remote/path');
      expect(note['sync_state'], 'pendingSync');
    },
  );

  test('keeping a conflicted note is an explicit guarded requeue', () async {
    const oldRevision = '00000000-0000-4000-8000-000000000000';
    const observedRevision = '33333333-3333-4333-8333-333333333333';
    const writeId = '11111111-1111-4111-8111-111111111111';
    await db.insert('note_pages', {
      'local_id': 'note-1',
      'sync_state': 'conflict',
      'remote_revision': oldRevision,
    });
    await insertOperation(
      'note-conflict',
      status: 'conflict',
      entityType: 'note_page',
      entityId: 'note-1',
      operationType: 'upsert',
      payload: jsonEncode({
        'patientLocalId': 'patient-1',
        'tabKey': 'Contexte de vie-Médical',
        'pageNumber': 0,
        'drawingJson': 'latest-local',
        'expectedRevision': oldRevision,
        'writeId': writeId,
        'conflict': {
          'remote': {
            'error': 'NOTE_PAGE_REVISION_CONFLICT',
            'remoteData': {'app_sync_revision': observedRevision},
          },
        },
      }),
    );

    expect(
      await repository.resolveNoteConflictKeepingLocal('note-conflict'),
      isTrue,
    );
    final operation = (await db.query(
      'sync_operations',
      where: 'id = ?',
      whereArgs: ['note-conflict'],
    )).single;
    final payload = jsonDecode(operation['payload_json'] as String) as Map;
    expect(operation['status'], 'pending');
    expect(payload['drawingJson'], 'latest-local');
    expect(payload['expectedRevision'], observedRevision);
    expect(payload.containsKey('conflict'), isFalse);
    expect(payload['writeId'], isNot(writeId));
    expect((await db.query('note_pages')).single['sync_state'], 'pendingSync');
  });

  test(
    'keeping a legacy missing-record conflict uses a freshly observed revision',
    () async {
      const observedRevision = '44444444-4444-4444-8444-444444444444';
      await db.insert('note_pages', {
        'local_id': 'note-legacy-conflict',
        'sync_state': 'conflict',
      });
      await insertOperation(
        'note-legacy-conflict-op',
        status: 'conflict',
        entityType: 'note_page',
        entityId: 'note-legacy-conflict',
        operationType: 'upsert',
        payload: jsonEncode({
          'patientLocalId': 'patient-1',
          'tabKey': 'notes_rapides',
          'pageNumber': 0,
          'drawingJson': 'latest-local',
          'expectedRevision': '00000000-0000-4000-8000-000000000000',
          'writeId': '11111111-1111-4111-8111-111111111111',
          'conflict': {
            'remote': {'error': 'NOTE_PAGE_RECORD_MISSING'},
          },
        }),
      );

      expect(
        await repository.resolveNoteConflictKeepingLocal(
          'note-legacy-conflict-op',
          observedRevision: observedRevision,
        ),
        isTrue,
      );
      final operation = (await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: ['note-legacy-conflict-op'],
      )).single;
      final payload = jsonDecode(operation['payload_json'] as String) as Map;
      expect(operation['status'], 'pending');
      expect(payload['expectedRevision'], observedRevision);
      expect(payload.containsKey('conflict'), isFalse);
      final note = (await db.query(
        'note_pages',
        where: 'local_id = ?',
        whereArgs: ['note-legacy-conflict'],
      )).single;
      expect(note['remote_revision'], observedRevision);
      expect(note['sync_state'], 'pendingSync');
    },
  );

  Future<Map<String, Object?>> document() async => (await db.query(
    'documents',
    where: 'local_id = ?',
    whereArgs: ['doc-1'],
  )).single;

  Future<String> operationStatus(String id) async =>
      (await db.query(
            'sync_operations',
            where: 'id = ?',
            whereArgs: [id],
          )).single['status']
          as String;

  Future<bool> complete(String id) => repository.markCompleted(
    operationId: id,
    entityType: 'document',
    entityLocalId: 'doc-1',
  );

  test('worker metadata does not retain queued attachment payloads', () async {
    final largePayload = '{"data":"${'x' * 1000000}"}';
    await insertOperation('one', payload: largePayload);
    await insertOperation('two', entityId: 'doc-2', payload: largePayload);
    final metadata = await repository.fetchRunnableOperations(
      includePayloads: false,
    );
    expect(metadata, hasLength(2));
    expect(metadata.every((op) => op.payloadJson.isEmpty), isTrue);
    final loaded = await repository.loadRunnablePayload(metadata.first);
    expect(loaded!.payloadJson, largePayload);
    expect(await repository.tryMarkRunning(loaded), isTrue);
    expect(metadata.every((op) => op.payloadJson.isEmpty), isTrue);
  });

  test('lazy payload loading defers a replaced snapshot', () async {
    await insertOperation('one');
    final snapshot = (await repository.fetchRunnableOperations(
      includePayloads: false,
    )).single;
    await db.update('sync_operations', {
      'payload_json': '{"localPath":"revision-2.pdf"}',
      'updated_at': DateTime(2026, 9, 10).toIso8601String(),
    });
    expect(await repository.loadRunnablePayload(snapshot), isNull);
    expect(await operationStatus('one'), 'pending');
  });

  test(
    'unreadable payload failure preserves bytes and is not auto-retried',
    () async {
      await insertOperation('unreadable', payload: 'unreadable-sealed-value');
      final snapshot = (await repository.fetchRunnableOperations(
        includePayloads: false,
      )).single;
      expect(await repository.markPreparationFailure(snapshot), isTrue);
      expect(await operationStatus('unreadable'), 'failed');
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        'unreadable-sealed-value',
      );
      await repository.rehabilitateTransientFailures();
      expect(await operationStatus('unreadable'), 'failed');
      expect((await document())['sync_state'], 'syncError');
    },
  );

  Future<void> storeRemote(String id) => repository.storeDocumentRemoteData(
    operationId: id,
    documentLocalId: 'doc-1',
    remotePath: 'uploaded-path',
    publicUrl: 'uploaded-url',
  );

  for (final rawTime in ['2026-09-10T00:00:00Z', '2026-09-10T02:00:00+02:00']) {
    test(
      'preparation failure accepts unchanged legacy timestamp $rawTime',
      () async {
        await insertOperation('legacy-time');
        await db.update('sync_operations', {'updated_at': rawTime});
        final snapshot = (await repository.fetchRunnableOperations(
          includePayloads: false,
        )).single;
        expect(await repository.markPreparationFailure(snapshot), isTrue);
        expect(await operationStatus('legacy-time'), 'failed');
      },
    );
  }

  for (final state in {
    'pending': 'pendingSync',
    'running': 'pendingSync',
    'failed': 'syncError',
    'conflict': 'conflict',
    'unknown-future-status': 'pendingSync',
  }.entries) {
    test(
      'completion retains ${state.value} when another op is ${state.key}',
      () async {
        await insertOperation('first', status: 'running');
        await insertOperation('second', status: state.key);
        await complete('first');
        expect(await operationStatus('first'), 'completed');
        expect(await operationStatus('second'), state.key);
        expect((await document())['sync_state'], state.value);
      },
    );
  }

  test(
    'only the final successful operation makes the document synced',
    () async {
      await insertOperation('first', status: 'running');
      await insertOperation('second', operationType: 'update_metadata');
      await complete('first');
      expect((await document())['sync_state'], 'pendingSync');

      final snapshot = (await repository.fetchRunnableOperations()).single;
      expect(await repository.tryMarkRunning(snapshot), isTrue);
      await complete('second');
      expect((await document())['sync_state'], 'synced');
    },
  );

  test(
    'operations belonging to other entities do not block completion',
    () async {
      await insertOperation('current', status: 'running');
      await insertOperation('other-document', entityId: 'doc-2');
      await insertOperation('same-id-other-type', entityType: 'note_page');
      await complete('current');
      expect((await document())['sync_state'], 'synced');
    },
  );

  for (final binding in {
    'note_page': 'note_pages',
    'patient': 'patients',
  }.entries) {
    test(
      'shared completion preserves remaining operations for ${binding.key}',
      () async {
        await db.insert(binding.value, {
          'local_id': 'entity-1',
          'sync_state': 'pendingSync',
        });
        await insertOperation(
          'first',
          status: 'running',
          entityType: binding.key,
          entityId: 'entity-1',
        );
        await insertOperation(
          'second',
          entityType: binding.key,
          entityId: 'entity-1',
        );
        await repository.markCompleted(
          operationId: 'first',
          entityType: binding.key,
          entityLocalId: 'entity-1',
        );
        expect(
          (await db.query(binding.value)).single['sync_state'],
          'pendingSync',
        );
      },
    );
  }

  test(
    'missing or replaced operation cannot acknowledge newer local work',
    () async {
      await complete('deleted');
      await insertOperation('replaced');
      await complete('replaced');
      expect(await operationStatus('replaced'), 'pending');
      expect((await document())['sync_state'], 'pendingSync');
    },
  );

  test('completion checks entity identity as well as operation id', () async {
    await insertOperation('other', status: 'running', entityId: 'doc-2');
    await complete('other');
    expect(await operationStatus('other'), 'running');
    expect((await document())['sync_state'], 'pendingSync');
  });

  test('operation completion rolls back if the entity update fails', () async {
    await insertOperation('current', status: 'running');
    await db.execute('''
      CREATE TRIGGER fail_document_update BEFORE UPDATE ON documents
      BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END
    ''');
    await expectLater(complete('current'), throwsA(isA<DatabaseException>()));
    expect(await operationStatus('current'), 'running');
    expect((await document())['sync_state'], 'pendingSync');
    await db.execute('DROP TRIGGER fail_document_update');
    await complete('current');
    expect((await document())['sync_state'], 'synced');
  });

  test('a pending snapshot can only be claimed once', () async {
    await insertOperation('current');
    final snapshot = (await repository.fetchRunnableOperations()).single;
    final claims = await Future.wait([
      repository.tryMarkRunning(snapshot),
      repository.tryMarkRunning(snapshot),
    ]);
    expect(claims.where((claimed) => claimed), hasLength(1));
    expect(await operationStatus('current'), 'running');
  });

  test('removed or changed queued snapshots are never claimed', () async {
    await insertOperation('current');
    final snapshot = (await repository.fetchRunnableOperations()).single;
    // Same timestamp deliberately: the payload comparison must protect this.
    await db.update(
      'sync_operations',
      {'payload_json': '{"new":"revision"}'},
      where: 'id = ?',
      whereArgs: ['current'],
    );
    expect(await repository.tryMarkRunning(snapshot), isFalse);
    expect(await operationStatus('current'), 'pending');
    await db.delete('sync_operations');
    expect(await repository.tryMarkRunning(snapshot), isFalse);
  });

  test(
    'current upload stores remote binding without acknowledging the document',
    () async {
      await insertOperation('current', status: 'running');
      await insertOperation('rename', operationType: 'update_metadata');
      await storeRemote('current');
      expect((await document())['remote_public_url'], 'uploaded-url');
      expect((await document())['sync_state'], 'pendingSync');
      await complete('current');
      expect((await document())['sync_state'], 'pendingSync');
    },
  );

  for (final status in ['pending', 'running', 'failed']) {
    test(
      'another $status upload prevents stale remote binding updates',
      () async {
        await insertOperation('old', status: 'running');
        await insertOperation('new', status: status);
        final before = await document();
        await storeRemote('old');
        expect(await document(), before);
      },
    );
  }

  test(
    'deleted or replaced upload cannot change remote data or visual version',
    () async {
      final before = await document();
      await storeRemote('deleted');
      expect(await document(), before);
      await insertOperation('replaced');
      await storeRemote('replaced');
      expect(await document(), before);
    },
  );

  test(
    'remote binding is not updated for a document pending deletion',
    () async {
      await insertOperation('current', status: 'running');
      await db.update('documents', {'pending_delete': 1});
      final before = await document();
      await storeRemote('current');
      expect(await document(), before);
    },
  );

  test(
    'completed upload history does not block the latest remote binding',
    () async {
      await insertOperation('old', status: 'completed');
      await insertOperation('new', status: 'running');
      await storeRemote('new');
      await complete('new');
      expect((await document())['remote_public_url'], 'uploaded-url');
      expect((await document())['sync_state'], 'synced');
    },
  );

  for (final status in [
    'failed',
    'running',
    'conflict',
    'unknown-future-status',
  ]) {
    test(
      '$status blocks following mutations only for the same entity',
      () async {
        await insertOperation('a-first', status: status);
        await insertOperation('b-following');
        await insertOperation('c-other', entityId: 'doc-2');
        expect(
          (await repository.fetchRunnableOperations()).map((op) => op.id),
          ['c-other'],
        );
      },
    );
  }

  test('a pending operation in backoff cannot be overtaken', () async {
    await insertOperation('a-first');
    await db.update('sync_operations', {
      'attempt_count': 2,
      'updated_at': DateTime.now().toIso8601String(),
    });
    await insertOperation('b-following');
    expect(await repository.fetchRunnableOperations(), isEmpty);
  });

  test(
    'a failure discovered after the snapshot prevents claiming the next op',
    () async {
      await insertOperation('a-first');
      await insertOperation('b-following');
      final following = (await repository.fetchRunnableOperations()).last;
      await db.update(
        'sync_operations',
        {'status': 'failed'},
        where: 'id = ?',
        whereArgs: ['a-first'],
      );
      expect(await repository.tryMarkRunning(following), isFalse);
    },
  );

  test(
    'unfinished count includes running and conflict, not completed history',
    () async {
      for (final status in [
        'pending',
        'running',
        'failed',
        'conflict',
        'completed',
      ]) {
        await insertOperation(status, status: status);
      }
      expect(await repository.countPendingOperations(), 4);
    },
  );

  test('completion returns false for a replaced mutation', () async {
    await insertOperation('current');
    expect(await complete('current'), isFalse);
    await db.update('sync_operations', {'status': 'running'});
    expect(await complete('current'), isTrue);
  });

  test(
    'housing acknowledgement uses the dossier foreign key and keeps newer edits pending',
    () async {
      await db.insert('housings', {
        'local_id': 'housing-1',
        'sync_state': 'pendingSync',
      });
      await db.insert('dossiers', {
        'local_id': 'dossier-1',
        'housing_local_id': 'housing-1',
      });
      await insertOperation(
        'first',
        entityType: 'housing',
        entityId: 'dossier-1',
        status: 'running',
      );
      await insertOperation(
        'second',
        entityType: 'housing',
        entityId: 'dossier-1',
      );
      await repository.markCompleted(
        operationId: 'first',
        entityType: 'housing',
        entityLocalId: 'dossier-1',
      );
      expect((await db.query('housings')).single['sync_state'], 'pendingSync');
      await db.update(
        'sync_operations',
        {'status': 'running'},
        where: 'id = ?',
        whereArgs: ['second'],
      );
      await repository.markCompleted(
        operationId: 'second',
        entityType: 'housing',
        entityLocalId: 'dossier-1',
      );
      expect((await db.query('housings')).single['sync_state'], 'synced');
    },
  );

  for (final replaced in [false, true]) {
    test(
      'remote version write respects payload ownership (replaced=$replaced)',
      () async {
        await db.insert('patients', {
          'local_id': 'patient-1',
          'sync_state': 'pendingSync',
          'remote_updated_at': 'old',
        });
        await insertOperation(
          'patient-update',
          entityType: 'patient',
          entityId: 'patient-1',
          operationType: 'update',
        );
        final op = (await repository.fetchRunnableOperations()).single;
        expect(await repository.tryMarkRunning(op), isTrue);
        if (replaced) {
          await db.update('sync_operations', {'payload_json': '{"new":true}'});
        }
        await repository.storeRemoteUpdatedAt(op, 'new');
        final row = (await db.query('patients')).single;
        expect(row['remote_updated_at'], replaced ? 'old' : 'new');
        expect(row['sync_state'], 'pendingSync');
      },
    );
  }

  for (final failCompletion in [false, true]) {
    test(
      'version and acknowledgement commit atomically (failure=$failCompletion)',
      () async {
        await db.insert('patients', {
          'local_id': 'patient-1',
          'sync_state': 'pendingSync',
          'remote_updated_at': 'old',
        });
        await insertOperation(
          'ack-patient',
          entityType: 'patient',
          entityId: 'patient-1',
          operationType: 'update',
          payload: '{"updates":{"invalidity":true}}',
        );
        final op = (await repository.fetchRunnableOperations()).single;
        await repository.tryMarkRunning(op);
        if (failCompletion) {
          await db.execute(
            "CREATE TRIGGER block_ack BEFORE UPDATE ON sync_operations "
            "WHEN NEW.status = 'completed' BEGIN SELECT RAISE(ABORT, 'test'); END",
          );
          await expectLater(
            repository.acknowledgeVersionedMutation(op, 'new'),
            throwsA(isA<DatabaseException>()),
          );
        } else {
          expect(
            await repository.acknowledgeVersionedMutation(op, 'new'),
            isTrue,
          );
        }
        expect(
          (await db.query('patients')).single['remote_updated_at'],
          failCompletion ? 'old' : 'new',
        );
        expect(
          await operationStatus('ack-patient'),
          failCompletion ? 'running' : 'completed',
        );
      },
    );
  }

  for (final kind in ['failed', 'transient', 'conflict']) {
    Future<void> reject(String id, {String entityId = 'doc-1'}) async {
      if (kind == 'conflict') {
        await repository.markConflict(
          operationId: id,
          entityType: 'document',
          entityLocalId: entityId,
          error: 'synthetic',
          expectedPayloadJson: '{"localPath":"revision-1.pdf"}',
        );
        return;
      }
      final transition = kind == 'failed'
          ? repository.markFailed
          : repository.markTransientFailure;
      await transition(
        operationId: id,
        entityType: 'document',
        entityLocalId: entityId,
        error: 'synthetic',
      );
    }

    test(
      '$kind transition and entity state roll back together on storage failure',
      () async {
        await insertOperation('current', status: 'running');
        await db.execute(
          "CREATE TRIGGER fail_state BEFORE UPDATE ON documents BEGIN SELECT RAISE(ABORT, 'synthetic disk error'); END",
        );
        await expectLater(reject('current'), throwsA(isA<DatabaseException>()));
        expect(await operationStatus('current'), 'running');
        expect((await document())['sync_state'], 'pendingSync');
        await db.execute('DROP TRIGGER fail_state');
        await reject('current');
        expect(
          await operationStatus('current'),
          kind == 'transient' ? 'pending' : kind,
        );
      },
    );

    test(
      '$kind transition cannot modify another entity or a replaced mutation',
      () async {
        await insertOperation('current', status: 'running');
        await reject('current', entityId: 'doc-2');
        expect(await operationStatus('current'), 'running');
        await db.update('sync_operations', {'status': 'pending'});
        await reject('current');
        expect(await operationStatus('current'), 'pending');
        expect((await document())['sync_state'], 'pendingSync');
      },
    );
  }

  for (final status in ['running', 'failed', 'conflict']) {
    test(
      'report waits for $status prerequisites of its own dossier only',
      () async {
        await db.insert('dossiers', {
          'local_id': 'dossier-1',
          'patient_local_id': 'patient-1',
        });
        await db.insert('dossiers', {
          'local_id': 'dossier-2',
          'patient_local_id': 'patient-2',
        });
        await insertOperation(
          'blocker',
          entityType: 'patient',
          entityId: 'patient-1',
          status: status,
        );
        await insertOperation(
          'report-1',
          entityType: 'report_generation',
          entityId: 'dossier-1',
        );
        await insertOperation(
          'report-2',
          entityType: 'report_generation',
          entityId: 'dossier-2',
        );
        expect(
          (await repository.fetchRunnableOperations()).map((op) => op.id),
          ['report-2'],
        );
        expect(
          await repository.countPendingReportPrerequisites(
            dossierId: 'dossier-1',
            patientId: 'patient-1',
          ),
          status == 'conflict' ? 0 : 1,
        );
        expect(
          await repository.countConflictingReportPrerequisites(
            dossierId: 'dossier-1',
            patientId: 'patient-1',
          ),
          status == 'conflict' ? 1 : 0,
        );
      },
    );
  }
}
