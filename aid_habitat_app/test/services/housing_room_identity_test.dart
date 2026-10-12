import 'dart:convert';
import 'package:aid_habitat_app/models/housing_rooms.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
    'legacy duplicate labels have deterministic distinct in-memory identities',
    () {
      final raw = jsonEncode([
        'Salle de bain',
        'Salle de bain',
        'Pièce inconnue',
      ]);
      final rooms = parseHousingRooms(raw, 'rdc');
      expect(rooms.map((r) => r.id).toSet().length, 3);
      expect(
        rooms.map((r) => r.id),
        parseHousingRooms(raw, 'rdc').map((r) => r.id),
      );
      expect(rooms.last.label, 'Pièce inconnue');
      expect(
        parseHousingRooms(raw, 'second_floor').first.id,
        parseHousingRooms(raw, 'secondFloor').first.id,
      );
      expect(createHousingRoom('WC').id, isNot(createHousingRoom('WC').id));
      expect(
        () => parseHousingRooms(
          '[{"id":"x","label":"a"},{"id":"x","label":"b"}]',
          'rdc',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'malformed room data remains readable and cannot be silently overwritten',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repo = DossierRepository(database: local);
      await repo.mergeRemoteDossierPayloads([
        {
          'id': 'broken',
          'patient': {'id': 'p'},
          'housing': {
            'id': 'h',
            'roomsBreakdown': {
              'rdc': {'bad': 'legacy'},
            },
          },
        },
      ]);
      final raw = (await db.query('housings')).single['rdc_rooms_json'];
      final dossiers = await repo.fetchAllDossiers();
      expect(
        dossiers.single.housing.roomIdentityErrors.containsKey('rdc'),
        isTrue,
      );
      await expectLater(
        repo.updateHousing('broken', {'rdc': true}),
        throwsFormatException,
      );
      expect((await db.query('housings')).single['rdc_rooms_json'], raw);
      expect(await db.query('sync_operations'), isEmpty);
    },
  );

  for (final count in [1, 2]) {
    test(
      'explicit room addition binds only unambiguous PRE-edit snapshot count=$count',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(db.close);
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        final repo = DossierRepository(database: local);
        await repo.mergeRemoteDossierPayloads([
          {
            'id': 'd',
            'patient': {'id': 'p'},
            'housing': {
              'id': 'h',
              'updatedAt': '2026-10-01T10:00:00Z',
              'roomsBreakdown': {
                'rdc': ['Salle de bain'],
              },
            },
          },
        ]);
        final original = [
          for (var i = 0; i < count; i++)
            {
              'id': 'diag-$i',
              'levelField': 'rdc',
              'customUnknown': 'keep',
              'porteSdbDimension': 70 + i,
            },
        ];
        await db.insert('diagnostic_sanitaires', {
          'local_id': 'diag',
          'dossier_local_id': 'd',
          'sdb_instances_json': jsonEncode(original),
          'wc_instances_json': '[]',
          'sync_state': 'synced',
          'remote_updated_at': '2026-10-01T10:00:00Z',
          'updated_at': '2026-10-01T10:00:00Z',
        });
        final rooms = parseHousingRooms('["Salle de bain"]', 'rdc');
        await repo.updateHousing('d', {
          'rdc_rooms_json': jsonEncode([
            ...rooms.map((r) => r.toJson()),
            createHousingRoom('Salle de bain').toJson(),
          ]),
        });
        final raw =
            jsonDecode(
                  (await db.query(
                        'diagnostic_sanitaires',
                      )).single['sdb_instances_json']
                      as String,
                )
                as List;
        if (count == 1) {
          expect(raw.single, {
            ...original.single,
            'housingRoomId': rooms.single.id,
          });
          final op = (await db.query(
            'sync_operations',
            where: 'entity_type = ?',
            whereArgs: ['diagnostic_sanitaires'],
          )).single;
          final payload = jsonDecode(
            await OfflineVault.instance.openString(
              op['payload_json'] as String,
            ),
          );
          expect(
            payload['concurrency']['baseValues']['sdbInstances'],
            original,
          );
          expect(
            payload['concurrency']['collectionContract'],
            'collections-v2',
          );
        } else {
          expect(raw, original);
          expect(
            await db.query(
              'sync_operations',
              where: 'entity_type = ?',
              whereArgs: ['diagnostic_sanitaires'],
            ),
            isEmpty,
          );
        }
      },
    );
  }

  test(
    'room identities survive API SQLite edit and exact diagnostic deletion',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      final repo = DossierRepository(database: local);
      await repo.mergeRemoteDossierPayloads([
        {
          'id': 'd1',
          'status': 'IN_PROGRESS',
          'updatedAt': '2026-10-01T10:00:00Z',
          'patient': {'id': 'p1', 'firstName': 'Fiction'},
          'housing': {
            'id': 'h1',
            'updatedAt': '2026-10-01T10:00:00Z',
            'roomsBreakdown': {
              'rdc': ['Salle de bain', 'Salle de bain'],
              '_roomIds': {
                'rdc': ['room-a', 'room-b'],
              },
            },
          },
        },
      ]);
      final before = await db.query('sync_operations');
      final housing = (await repo.fetchDossierById('d1'))!.housing;
      expect(housing.rdcRooms, ['Salle de bain', 'Salle de bain']);
      expect(housing.roomsByLevel['rdc']!.map((r) => r.id), [
        'room-a',
        'room-b',
      ]);
      expect(await db.query('sync_operations'), before);
      await repo.updateHousing('d1', {
        'rdc_rooms_json': jsonEncode([
          housing.roomsByLevel['rdc']!.last.toJson(),
        ]),
      });
      final op = (await db.query('sync_operations')).single;
      final payload = jsonDecode(
        await OfflineVault.instance.openString(op['payload_json'] as String),
      );
      expect(payload['updates']['roomsBreakdown']['rdc'], ['Salle de bain']);
      expect(payload['updates']['roomsBreakdown']['_roomIds']['rdc'], [
        'room-b',
      ]);
      await repo.upsertDiagnosticSanitaire(
        'd1',
        DiagnosticSanitaire(
          dossierId: 'd1',
          sdbInstances: const [
            BathroomInstance(
              id: 'diag-a',
              housingRoomId: 'room-a',
              levelField: 'rdc',
              porteSdbDimension: 71,
            ),
            BathroomInstance(
              id: 'diag-b',
              housingRoomId: 'room-b',
              levelField: 'rdc',
              porteSdbDimension: 89,
            ),
          ],
          wcInstances: const [
            WcInstance(id: 'wc-a', housingRoomId: 'room-wc', levelField: 'rdc'),
          ],
        ),
      );
      final storedBeforeRemoval = (await db.query(
        'diagnostic_sanitaires',
      )).single;
      final rawToilets =
          jsonDecode(storedBeforeRemoval['wc_instances_json'] as String)
              as List;
      (rawToilets.single as Map)['futureField'] = 'preserve unknown';
      (rawToilets.single as Map)['observationEquipementsUtilisation'] =
          'Observation fictive complète';
      await db.update('diagnostic_sanitaires', {
        'wc_instances_json': jsonEncode(rawToilets),
      });
      await repo.removeDiagnosticRooms(
        'd1',
        bathroomIds: {'diag-a'},
        wcIds: {},
      );
      final diag = (await repo.fetchDiagnosticSanitaire('d1'))!;
      expect(diag.sdbInstances.single.id, 'diag-b');
      expect(diag.sdbInstances.single.housingRoomId, 'room-b');
      expect(diag.sdbInstances.single.porteSdbDimension, 89);
      expect(diag.wcInstances.single.id, 'wc-a');
      expect(
        jsonDecode(
          (await db.query('diagnostic_sanitaires')).single['wc_instances_json']
              as String,
        ),
        rawToilets,
      );
    },
  );
}
