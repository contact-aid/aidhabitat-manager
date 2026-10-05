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
    expect(parseHousingRooms(raw, 'second_floor').first.id, parseHousingRooms(raw, 'secondFloor').first.id);
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
    },
  );
}
