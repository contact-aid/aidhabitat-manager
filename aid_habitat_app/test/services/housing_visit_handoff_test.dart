import 'dart:convert';

import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/housing_visit_handoff.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_conflict_resolution_test.dart' show remote;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository dossiers;
  late SyncRepository queue;
  final today = DateTime.now().toIso8601String().substring(0, 10);
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    dossiers = DossierRepository(database: local);
    queue = SyncRepository.forTesting(database: local);
    await dossiers.mergeRemoteDossierPayloads([remote()]);
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> payload() async => jsonDecode(
    await OfflineVault.instance.openString(
      (await db.query('sync_operations')).single['payload_json'] as String,
    ),
  );

  test(
    'opening an old report or preparing tomorrow does not begin a visit',
    () async {
      await dossiers.beginHousingVisit('dossier-1', '2000-01-01');
      expect(await HousingVisitHandoff.read(db, 'dossier-1'), isNull);
      await dossiers.beginHousingVisit('dossier-1', '2099-01-01');
      expect(await HousingVisitHandoff.read(db, 'dossier-1'), isNull);
    },
  );

  test(
    'an existing queue is not enrolled or upgraded, even when edited again',
    () async {
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final old = await payload();
      (old['concurrency'] as Map).remove('housingPolicy');
      await db.update('sync_operations', {
        'payload_json': await OfflineVault.instance.sealString(jsonEncode(old)),
      });
      await dossiers.beginHousingVisit('dossier-1', today);
      expect(await HousingVisitHandoff.read(db, 'dossier-1'), isNull);
      expect(await payload(), old);
      await dossiers.updateHousing('dossier-1', {'surface': 91});
      expect((await payload())['concurrency']['housingPolicy'], isNull);
      expect((await payload())['housingVisit'], isNull);
    },
  );

  test(
    'new visit snapshots its reference before the first transmission',
    () async {
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final sent = await payload();
      expect(sent['housingVisit']['phase'], 'first');
      expect(
        sent['concurrency']['housingPolicy'],
        HousingVisitHandoff.protocol,
      );
      final history = (await db.query('sync_conflict_history')).single;
      final snapshot = jsonDecode(
        await OfflineVault.instance.openString(
          history['snapshot_json'] as String,
        ),
      );
      expect(snapshot['referenceValues']['surface'], 80);
      expect(snapshot['mutation']['updates']['surface'], 90);
      expect(await HousingVisitHandoff.read(db, 'another-dossier'), isNull);
    },
  );

  test('changing the appointment time does not rearm the same visit', () async {
    await dossiers.beginHousingVisit('dossier-1', '${today}T09:00:00');
    final marker = await HousingVisitHandoff.read(db, 'dossier-1');
    await HousingVisitHandoff.settle(db, 'dossier-1', marker);
    await dossiers.beginHousingVisit('dossier-1', '${today}T11:00:00');
    expect(
      (await HousingVisitHandoff.read(db, 'dossier-1'))!['phase'],
      'normal',
    );
  });

  test('legacy housing-id queue also prevents enrollment', () async {
    await dossiers.updateHousing('dossier-1', {'surface': 90});
    final housing = (await db.query('dossiers')).single['housing_local_id'];
    await db.update('sync_operations', {'entity_local_id': housing});
    await dossiers.beginHousingVisit('dossier-1', today);
    expect(await HousingVisitHandoff.read(db, 'dossier-1'), isNull);
  });

  test(
    'uncertain first response consumes priority durably before a retry',
    () async {
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final sent = await payload();
      final id = sent['concurrency']['writeId'] as String;
      expect(
        await HousingVisitHandoff.claim(
          db,
          'dossier-1',
          sent['housingVisit'],
          id,
        ),
        isTrue,
      );
      // A new repository instance simulates recreation after process loss.
      await DossierRepository(
        database: LocalDatabase.forTesting(db),
      ).beginHousingVisit('dossier-1', today);
      expect(
        await HousingVisitHandoff.claim(
          db,
          'dossier-1',
          sent['housingVisit'],
          id,
        ),
        isFalse,
      );
      expect(
        await HousingVisitHandoff.mayPreferVisit(db, 'dossier-1', sent),
        isFalse,
      );
      expect(
        (await HousingVisitHandoff.read(db, 'dossier-1'))!['phase'],
        'attempted',
      );
    },
  );

  test(
    'definitive rejection permits one archived rebase, never a second one',
    () async {
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final op = (await queue.fetchRunnableOperations()).single;
      final sent = await payload();
      final id = sent['concurrency']['writeId'] as String;
      await HousingVisitHandoff.claim(
        db,
        'dossier-1',
        sent['housingVisit'],
        id,
      );
      await HousingVisitHandoff.rejected(db, 'dossier-1', id);
      expect(
        await HousingVisitHandoff.mayPreferVisit(db, 'dossier-1', sent),
        isTrue,
      );
      await queue.tryMarkRunning(op);
      await queue.markConflict(
        operationId: op.id,
        entityType: op.entityType,
        entityLocalId: op.entityLocalId,
        error: 'Synthetic conflict',
        expectedPayloadJson: op.payloadJson,
      );
      final server = remote(version: '2026-09-02T10:00:00.000Z');
      (server['housing'] as Map)['surface'] = 100;
      final review = (await dossiers.reviewConflicts(
        'dossier-1',
        server,
      )).single;
      await dossiers.resolveReviewedConflict(review, keepLocal: true);
      final rebased = await payload();
      expect(rebased['housingVisit']['phase'], 'normal');
      expect(
        rebased['concurrency']['housingPolicy'],
        HousingVisitHandoff.protocol,
      );
      expect(rebased['concurrency']['baseValues']['surface'], 100);
      expect(rebased['updates']['surface'], 90);
      expect(
        await HousingVisitHandoff.mayPreferVisit(db, 'dossier-1', sent),
        isFalse,
      );
      expect(await db.query('sync_conflict_history'), hasLength(2));
    },
  );

  test(
    'acknowledgement ends priority atomically and reopening cannot rearm it',
    () async {
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final op = (await queue.fetchRunnableOperations()).single;
      await queue.tryMarkRunning(op);
      expect(
        await queue.acknowledgeVersionedMutation(
          op,
          '2026-09-02T10:00:00.000Z',
        ),
        isTrue,
      );
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 91});
      expect((await payload())['housingVisit']['phase'], 'normal');
      expect((await payload())['concurrency']['baseValues']['surface'], 90);
    },
  );

  test(
    'an edit during upload keeps its data but loses predecessor priority after ack',
    () async {
      await dossiers.beginHousingVisit('dossier-1', today);
      await dossiers.updateHousing('dossier-1', {'surface': 90});
      final sent = (await queue.fetchRunnableOperations()).single;
      await queue.tryMarkRunning(sent);
      await dossiers.updateHousing('dossier-1', {'surface': 91});
      expect(
        await queue.acknowledgeVersionedMutation(
          sent,
          '2026-09-02T10:00:00.000Z',
        ),
        isFalse,
      );
      final next = await payload();
      expect(next['housingVisit']['phase'], 'normal');
      expect(next['updates']['surface'], 91);
      expect(next['concurrency']['baseValues']['surface'], 90);
      expect(
        (await HousingVisitHandoff.read(db, 'dossier-1'))!['phase'],
        'normal',
      );
    },
  );
}
