import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _version = '2026-09-01T10:00:00.000Z';
const _later = '2026-09-03T10:00:00.000Z';
const _types = [
  'contexte_de_vie',
  'mesures_anthropometriques',
  'observations_synthese',
  'diagnostic_sanitaires',
  'visit_recommendations',
];

MedicalContext _medical(int n) => MedicalContext(pathology: 'medical-$n');
VisitRecommendationItem _item(int n) => VisitRecommendationItem(
  id: 'item-1',
  wikiItemId: 'wiki-1',
  note: 'note-$n',
);
DiagnosticSanitaire _diagnostic(int n) => DiagnosticSanitaire.fromJson({
  'dossierId': 'dossier-1',
  'sdbInstances': [
    {'id': 'bath-$n', 'levelField': 'rdc'},
  ],
  'wcInstances': [
    {'id': 'wc-$n', 'levelField': 'rdc'},
  ],
});

Map<String, dynamic> _values(String type, int n) => switch (type) {
  'contexte_de_vie' => {'medicalContext': _medical(n).toJson()},
  'mesures_anthropometriques' => {'observations': 'measure-$n'},
  'observations_synthese' => {'projetSouhaitUsage': 'project-$n'},
  'diagnostic_sanitaires' => {
    'sdbInstances': _diagnostic(n).toJson()['sdbInstances'],
    'wcInstances': _diagnostic(n).toJson()['wcInstances'],
  },
  'visit_recommendations' => {
    'items': [_item(n).toJson()],
  },
  _ => throw StateError(type),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository repository;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = DossierRepository(database: local);
    await repository.mergeRemoteDossierPayloads([
      {
        'id': 'dossier-1',
        'createdAt': _version,
        'updatedAt': _version,
        'workspaceUpdatedAt': _version,
        'patient': {'id': 'patient-1', 'firstName': 'Synthetic'},
        'housing': {'surface': 80},
        'medicalContext': _medical(0).toJson(),
        'autonomy': const AutonomyData().toJson(),
      },
    ]);
    await repository.mergeRemoteMesuresPayload('dossier-1', {
      'observations': 'measure-0',
    });
    await repository.mergeRemoteObservationsPayload('dossier-1', {
      'projetSouhaitUsage': 'project-0',
    });
    await repository.mergeRemoteDiagnosticSanitairePayload(
      'dossier-1',
      _diagnostic(0).toJson(),
    );
    await repository.mergeRemoteVisitRecommendationsPayload('dossier-1', [
      _item(0).toJson(),
    ]);
  });
  tearDown(() async => db.close());

  Future<void> edit(String type, int n) => switch (type) {
    'contexte_de_vie' => repository.upsertContexteDeVie(
      'dossier-1',
      'patient-1',
      medicalContext: _medical(n),
    ),
    'mesures_anthropometriques' => repository.upsertMesures(
      'dossier-1',
      MesuresAnthropometriques(
        dossierId: 'dossier-1',
        observations: 'measure-$n',
      ),
    ),
    'observations_synthese' => repository.upsertObservations(
      'dossier-1',
      ObservationsSynthese(
        dossierId: 'dossier-1',
        projetSouhaitUsage: 'project-$n',
      ),
    ),
    'diagnostic_sanitaires' => repository.upsertDiagnosticSanitaire(
      'dossier-1',
      _diagnostic(n),
    ),
    'visit_recommendations' => repository.saveVisitRecommendations(
      'dossier-1',
      [_item(n)],
    ),
    _ => throw StateError(type),
  };

  Future<Map<String, Object?>> queued(String type) async => (await db.query(
    'sync_operations',
    where: 'entity_type = ?',
    whereArgs: [type],
  )).single;
  Future<Map<String, Object?>> row(String type) async =>
      (await db.query(type)).single;
  Future<Map<String, dynamic>> payload(String type) async =>
      jsonDecode(
            await OfflineVault.instance.openString(
              (await queued(type))['payload_json'] as String,
            ),
          )
          as Map<String, dynamic>;
  Future<void> changeOp(String type, Map<String, Object?> fields) async {
    await db.update(
      'sync_operations',
      fields,
      where: 'entity_type = ?',
      whereArgs: [type],
    );
  }

  for (final type in _types) {
    group(type, () {
      test(
        'captures the pre-edit reference and preserves local identity',
        () async {
          final before = await row(type);
          await edit(type, 1);
          final op = await payload(type);
          expect(op['updates'], _values(type, 1));
          expect(op['localReference']['baseValues'], _values(type, 0));
          expect(op['localReference']['expectedUpdatedAt'], isNull);
          expect(op.containsKey('concurrency'), isFalse);
          expect((await row(type))['local_id'], before['local_id']);
          expect((await row(type))['dossier_local_id'], 'dossier-1');
          expect(op['dossierId'], 'dossier-1');
          if (type == 'diagnostic_sanitaires' ||
              type == 'visit_recommendations') {
            for (final key in _values(type, 1).keys) {
              expect(
                op[key],
                op['updates'][key],
                reason: 'Existing PUT transport reads root fields',
              );
            }
          }
        },
      );

      for (final status in ['pending', 'running', 'failed', 'conflict']) {
        test(
          'editing $status retains the original baseline and conflict evidence',
          () async {
            await edit(type, 1);
            final before = await payload(type);
            if (status == 'conflict') {
              before['conflict'] = {
                'remoteUpdatedAt': _later,
                'fields': ['synthetic'],
              };
            }
            await changeOp(type, {
              'status': status,
              'payload_json': await OfflineVault.instance.sealString(
                jsonEncode(before),
              ),
              'attempt_count': 3,
              'last_error': 'original error',
              'created_at': _version,
            });
            await db.update('dossiers', {'remote_updated_at': _later});
            await edit(type, 2);
            final after = await payload(type);
            expect(after['updates'], _values(type, 2));
            expect(after['localReference']['baseValues'], _values(type, 0));
            expect(
              after['localReference']['expectedUpdatedAt'],
              before['localReference']['expectedUpdatedAt'],
            );
            expect(
              after['localReference']['writeId'],
              isNot(before['localReference']['writeId']),
            );
            expect((await queued(type))['created_at'], _version);
            if (status == 'conflict') {
              expect(after['conflict'], before['conflict']);
              expect((await queued(type))['status'], 'conflict');
              expect((await queued(type))['last_error'], 'original error');
              expect((await queued(type))['attempt_count'], 3);
              expect((await row(type))['sync_state'], 'conflict');
            }
            expect(await db.query('sync_conflict_history'), isEmpty);
          },
        );
      }

      test(
        'legacy conflict without metadata cannot acquire a fabricated baseline',
        () async {
          await edit(type, 1);
          final old = {
            'dossierId': 'dossier-1',
            if (type == 'diagnostic_sanitaires' ||
                type == 'visit_recommendations')
              ..._values(type, 1)
            else
              'updates': _values(type, 1),
          };
          await changeOp(type, {
            'status': 'conflict',
            'payload_json': jsonEncode(old),
          });
          await edit(type, 2);
          final op = await payload(type);
          expect(op['localReference']['baseValues'], isEmpty);
          expect(op['localReference']['expectedUpdatedAt'], isNull);
          expect(op['updates'], _values(type, 2));
          expect(op.containsKey('conflict'), isTrue);
          expect((await queued(type))['status'], 'conflict');
          expect((await row(type))['sync_state'], 'conflict');
        },
      );

      test('completed operation allows a fresh reference', () async {
        await edit(type, 1);
        await changeOp(type, {'status': 'completed'});
        await db.update(type, {'sync_state': 'synced'});
        await db.update('dossiers', {'remote_updated_at': _later});
        await edit(type, 2);
        final op = await payload(type);
        expect(op['localReference']['baseValues'], _values(type, 1));
        expect(op['localReference']['expectedUpdatedAt'], isNull);
        expect(op.containsKey('conflict'), isFalse);
      });

      for (final status in ['pending', 'conflict']) {
        test(
          'an existing $status version guard is retained, not recaptured',
          () async {
            await edit(type, 1);
            final old = await payload(type);
            old['concurrency'] = old.remove('localReference');
            old['concurrency']['expectedUpdatedAt'] = _version;
            await changeOp(type, {
              'status': status,
              'payload_json': jsonEncode(old),
            });
            await db.update('dossiers', {'remote_updated_at': _later});
            await edit(type, 2);
            final next = await payload(type);
            expect(next['concurrency']['baseValues'], _values(type, 0));
            expect(next['concurrency']['expectedUpdatedAt'], _version);
            expect(next.containsKey('localReference'), isFalse);
            expect((await queued(type))['status'], status);
          },
        );
      }

      test(
        'simultaneous first saves share one row and preserve create-only guard',
        () async {
          await db.delete(type);
          await Future.wait([edit(type, 1), edit(type, 2)]);
          expect(await db.query(type), hasLength(1));
          final next = await payload(type);
          // A newly inserted scalar row also queues its default empty fields.
          for (final entry in _values(type, 2).entries) {
            expect(next['updates'][entry.key], entry.value);
          }
          if (type == 'visit_recommendations') {
            expect(next['localReference']['baseValues'], isEmpty);
            expect(next.containsKey('concurrency'), isFalse);
            return;
          }
          expect(next['concurrency']['baseValues'], isEmpty);
          expect(next.containsKey('localReference'), isFalse);
          if (type == 'contexte_de_vie') {
            expect(next['concurrency'].containsKey('reference'), isTrue);
            expect(next['concurrency']['reference'], isNull);
          } else {
            expect(next['concurrency']['createIfAbsent'], isTrue);
          }
        },
      );

      if (type != 'diagnostic_sanitaires') {
        test(
          'unchanged conflict save leaves the operation untouched',
          () async {
            await edit(type, 1);
            await changeOp(type, {'status': 'conflict'});
            final before = await queued(type);
            await edit(type, 1);
            expect(await queued(type), before);
          },
        );
      }

      test(
        'orphan conflict row stays blocked without inventing references',
        () async {
          await db.update(type, {'sync_state': 'conflict'});
          await edit(type, 1);
          expect(
            (await payload(type))['localReference']['baseValues'],
            isEmpty,
          );
          expect((await queued(type))['status'], 'conflict');
          expect((await row(type))['sync_state'], 'conflict');
        },
      );

      for (final broken in ['broken-json', '{"updates":null}']) {
        test('invalid payload $broken rolls back the whole save', () async {
          await edit(type, 1);
          await changeOp(type, {'payload_json': broken});
          final before = await row(type);
          await expectLater(edit(type, 2), throwsFormatException);
          expect(await row(type), before);
          expect((await queued(type))['payload_json'], broken);
        });
      }

      test('queue write failure rolls back local data and reference', () async {
        await edit(type, 1);
        final beforeRow = await row(type);
        final beforeOp = await queued(type);
        await db.execute(
          "CREATE TRIGGER reject_secondary BEFORE INSERT ON sync_operations BEGIN SELECT RAISE(ABORT, 'test failure'); END",
        );
        await expectLater(edit(type, 2), throwsA(isA<DatabaseException>()));
        expect(await row(type), beforeRow);
        expect(await queued(type), beforeOp);
      });
    });
  }

  test(
    'context edits to separate objects coalesce against their own references',
    () async {
      await Future.wait([
        repository.upsertContexteDeVie(
          'dossier-1',
          'patient-1',
          medicalContext: _medical(1),
        ),
        repository.upsertContexteDeVie(
          'dossier-1',
          'patient-1',
          autonomy: const AutonomyData(done: true),
        ),
      ]);
      final op = await payload('contexte_de_vie');
      expect(op['updates'], {
        'medicalContext': _medical(1).toJson(),
        'autonomy': const AutonomyData(done: true).toJson(),
      });
      expect(op['localReference']['baseValues'], {
        'medicalContext': _medical(0).toJson(),
        'autonomy': const AutonomyData().toJson(),
      });
    },
  );

  test('a newly changed scalar retains earlier unsent fields', () async {
    await edit('mesures_anthropometriques', 1);
    await repository.upsertMesures(
      'dossier-1',
      const MesuresAnthropometriques(
        dossierId: 'dossier-1',
        observations: 'measure-1',
        assisHauteurAssise: 48,
      ),
    );
    final op = await payload('mesures_anthropometriques');
    expect(op['updates'], {
      'observations': 'measure-1',
      'assisHauteurAssise': 48,
    });
    expect(op['localReference']['baseValues'], {
      'observations': 'measure-0',
      'assisHauteurAssise': null,
    });
  });

  test(
    'draft-only withdrawal preserves the conflict reference across a later linked edit',
    () async {
      const type = 'visit_recommendations';
      await edit(type, 1);
      await changeOp(type, {
        'status': 'conflict',
        'last_error': 'original conflict',
      });
      final before = await queued(type);
      final beforePayload = await payload(type);
      await repository.saveVisitRecommendations('dossier-1', [
        const VisitRecommendationItem(id: 'draft', customTitle: 'Draft'),
      ]);
      final withdrawal = await payload(type);
      expect(withdrawal['items'], isEmpty);
      expect(withdrawal['updates'], {'items': []});
      expect(
        withdrawal['localReference']['baseValues'],
        beforePayload['localReference']['baseValues'],
      );
      expect((await queued(type))['status'], 'conflict');
      expect((await queued(type))['last_error'], before['last_error']);
      expect((await row(type))['sync_state'], 'conflict');
      expect(
        (await repository.fetchVisitRecommendations(
          'dossier-1',
        )).single.customTitle,
        'Draft',
      );
      expect(
        await repository.mergeRemoteVisitRecommendationsPayload(
          'dossier-1',
          [],
        ),
        isFalse,
      );
      await edit(type, 2);
      expect(
        (await payload(type))['localReference']['baseValues'],
        _values(type, 0),
      );
      expect((await queued(type))['status'], 'conflict');
    },
  );

  for (final status in ['pending', 'running', 'failed']) {
    test(
      'draft-only edit replaces a $status intention with withdrawal and preserves the draft',
      () async {
        const type = 'visit_recommendations';
        await edit(type, 1);
        await changeOp(type, {'status': status});
        final beforeOp = await queued(type);
        final before = await payload(type);
        const draft = VisitRecommendationItem(
          id: 'draft',
          note: 'Keep my text',
        );
        await repository.saveVisitRecommendations('dossier-1', [draft]);
        final next = await payload(type);
        expect(next['items'], isEmpty);
        expect(next['updates'], {'items': []});
        expect(
          next['localReference']['baseValues'],
          before['localReference']['baseValues'],
        );
        expect(
          next['localReference']['writeId'],
          isNot(before['localReference']['writeId']),
        );
        expect((await queued(type))['id'], beforeOp['id']);
        expect((await queued(type))['status'], 'pending');
        expect(jsonDecode((await row(type))['items_json'] as String), [
          draft.toJson(),
        ]);
        expect((await row(type))['sync_state'], 'pendingSync');
        if (status == 'running') {
          final sync = SyncRepository.forTesting(
            databaseProvider: () async => db,
          );
          expect(
            await sync.markCompleted(
              operationId: beforeOp['id'] as String,
              entityType: type,
              entityLocalId: 'dossier-1',
            ),
            isFalse,
            reason: 'The earlier request cannot acknowledge the new withdrawal',
          );
        }
      },
    );
  }

  test(
    'new recommendation drafts remain local and explicit deletion stays conflicted',
    () async {
      await db.delete('visit_recommendations');
      await repository.saveVisitRecommendations('dossier-1', [
        const VisitRecommendationItem(id: 'draft'),
      ]);
      expect(await db.query('sync_operations'), isEmpty);
      await edit('visit_recommendations', 1);
      await changeOp('visit_recommendations', {'status': 'conflict'});
      final before = await payload('visit_recommendations');
      await repository.saveVisitRecommendations(
        'dossier-1',
        [],
        forceSync: true,
      );
      final after = await payload('visit_recommendations');
      expect(after['items'], isEmpty);
      expect(
        after['localReference']['baseValues'],
        before['localReference']['baseValues'],
      );
      expect((await queued('visit_recommendations'))['status'], 'conflict');
    },
  );

  test('forceSync is not a conflict bypass', () async {
    await edit('visit_recommendations', 1);
    await changeOp('visit_recommendations', {'status': 'conflict'});
    await repository.saveVisitRecommendations('dossier-1', [
      _item(1),
    ], forceSync: true);
    expect((await queued('visit_recommendations'))['status'], 'conflict');
    expect(
      (await payload('visit_recommendations'))['localReference']['baseValues'],
      _values('visit_recommendations', 0),
    );
  });

  for (final existingEmptyRow in [false, true]) {
    test(
      'first drafts never enqueue a remote clear (existing row: $existingEmptyRow)',
      () async {
        const type = 'visit_recommendations';
        await db.delete(type);
        if (existingEmptyRow) {
          await repository.mergeRemoteVisitRecommendationsPayload(
            'dossier-1',
            [],
          );
        }
        const draft = VisitRecommendationItem(id: 'draft', note: 'New note');
        await repository.saveVisitRecommendations('dossier-1', [
          draft,
        ], forceSync: true);
        expect(await db.query('sync_operations'), isEmpty);
        expect(jsonDecode((await row(type))['items_json'] as String), [
          draft.toJson(),
        ]);
        await repository.saveVisitRecommendations('dossier-1', [
          const VisitRecommendationItem(id: 'draft', note: 'Edited note'),
        ]);
        expect(await db.query('sync_operations'), isEmpty);
        await repository.saveVisitRecommendations(
          'dossier-1',
          [],
          forceSync: true,
        );
        expect(await db.query('sync_operations'), isEmpty);
      },
    );
  }

  test(
    'previously fetched linked items are withdrawn even without an earlier queued operation',
    () async {
      const type = 'visit_recommendations';
      const draft = VisitRecommendationItem(
        id: 'draft',
        customTitle: 'Replacement in progress',
      );
      await repository.saveVisitRecommendations('dossier-1', [draft]);
      final next = await payload(type);
      expect(next['items'], isEmpty);
      expect(next['localReference']['baseValues'], _values(type, 0));
      expect(next.containsKey('concurrency'), isFalse);
      expect((await queued(type))['status'], 'pending');
      expect(jsonDecode((await row(type))['items_json'] as String), [
        draft.toJson(),
      ]);
    },
  );

  test(
    'draft withdrawal retains an existing guard and detailed conflict evidence',
    () async {
      const type = 'visit_recommendations';
      await edit(type, 1);
      final before = await payload(type);
      before['concurrency'] = before.remove('localReference');
      before['concurrency']['expectedUpdatedAt'] = _version;
      before['conflict'] = {
        'remoteUpdatedAt': _later,
        'fields': ['items'],
      };
      await changeOp(type, {
        'status': 'conflict',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode(before),
        ),
        'attempt_count': 4,
        'last_error': 'List changed remotely',
      });
      await repository.saveVisitRecommendations('dossier-1', [
        const VisitRecommendationItem(id: 'draft', note: 'Keep typing'),
      ]);
      final next = await payload(type);
      expect(next['items'], isEmpty);
      expect(
        next['concurrency']['baseValues'],
        before['concurrency']['baseValues'],
      );
      expect(next['concurrency']['expectedUpdatedAt'], _version);
      expect(next['conflict'], before['conflict']);
      expect((await queued(type))['status'], 'conflict');
      expect((await queued(type))['attempt_count'], 4);
      expect((await queued(type))['last_error'], 'List changed remotely');
    },
  );

  test(
    'editing drafts during withdrawal retains the original reference and invalidates the earlier acknowledgement',
    () async {
      const type = 'visit_recommendations';
      await repository.saveVisitRecommendations('dossier-1', [
        const VisitRecommendationItem(id: 'draft', note: 'First draft'),
      ]);
      final before = await payload(type);
      final id = (await queued(type))['id'] as String;
      final sync = SyncRepository.forTesting(databaseProvider: () async => db);
      await sync.markRunning(id);
      await repository.saveVisitRecommendations('dossier-1', [
        const VisitRecommendationItem(id: 'draft', note: 'Latest draft'),
      ]);
      final next = await payload(type);
      expect(next['items'], isEmpty);
      expect(
        next['localReference']['baseValues'],
        before['localReference']['baseValues'],
      );
      expect(
        next['localReference']['writeId'],
        isNot(before['localReference']['writeId']),
      );
      expect(
        await sync.markCompleted(
          operationId: id,
          entityType: type,
          entityLocalId: 'dossier-1',
        ),
        isFalse,
      );
      expect(
        (await repository.fetchVisitRecommendations('dossier-1')).single.note,
        'Latest draft',
      );
    },
  );

  test(
    'withdrawal acknowledgement and subsequent pulls preserve local drafts after reopening the repository',
    () async {
      const type = 'visit_recommendations';
      const draft = VisitRecommendationItem(
        id: 'draft',
        customTitle: 'Unfinished',
        note: 'Keep all of this',
      );
      await repository.saveVisitRecommendations('dossier-1', [draft]);
      final id = (await queued(type))['id'] as String;
      final sync = SyncRepository.forTesting(databaseProvider: () async => db);
      await sync.markRunning(id);
      expect(
        await sync.markCompleted(
          operationId: id,
          entityType: type,
          entityLocalId: 'dossier-1',
        ),
        isTrue,
      );
      expect((await row(type))['sync_state'], 'synced');
      expect(jsonDecode((await row(type))['items_json'] as String), [
        draft.toJson(),
      ]);
      repository = DossierRepository(database: LocalDatabase.forTesting(db));
      // Age only the test acknowledgement to exercise the pull beyond the
      // replica-protection window, rather than merely testing its early exit.
      await changeOp(type, {'updated_at': _version});
      expect(
        await repository.mergeRemoteVisitRecommendationsPayload(
          'dossier-1',
          [],
        ),
        isTrue,
      );
      expect(jsonDecode((await row(type))['items_json'] as String), [
        draft.toJson(),
      ]);
      final completed = await queued(type);
      await repository.saveVisitRecommendations('dossier-1', [
        draft,
      ], forceSync: true);
      expect(
        await queued(type),
        completed,
        reason: 'An acknowledged empty list does not need another withdrawal',
      );
      expect(
        await repository.mergeRemoteVisitRecommendationsPayload('dossier-1', [
          _item(2).toJson(),
        ]),
        isTrue,
      );
      expect(jsonDecode((await row(type))['items_json'] as String), [
        _item(2).toJson(),
        draft.toJson(),
      ]);
      expect(
        await repository.mergeRemoteVisitRecommendationsPayload(
          'dossier-1',
          [],
        ),
        isTrue,
      );
      expect(jsonDecode((await row(type))['items_json'] as String), [
        draft.toJson(),
      ]);
    },
  );

  test(
    'recommendation reference excludes drafts but keeps uncached remote links',
    () async {
      await db.update('visit_recommendations', {
        'items_json': jsonEncode([
          _item(0).toJson(),
          const VisitRecommendationItem(id: 'draft').toJson(),
        ]),
      });
      await edit('visit_recommendations', 1);
      expect(
        (await payload(
          'visit_recommendations',
        ))['localReference']['baseValues'],
        _values('visit_recommendations', 0),
      );
    },
  );

  test(
    'a partial library cache never removes a published recommendation',
    () async {
      await db.insert('wiki_items', {
        'id': 'unrelated',
        'title': 'Other',
        'description': '',
        'image_url': '',
        'tags_json': '[]',
        'category': '',
        'created_at': '2026-01-01',
        'updated_at': '2026-01-01',
        'last_synced_at': '2026-01-01',
        'sync_state': 'synced',
      });
      await edit('visit_recommendations', 1);
      final saved = await payload('visit_recommendations');
      expect(saved['items'], [_item(1).toJson()]);
    },
  );
}
