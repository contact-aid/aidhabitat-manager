import 'dart:convert';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/note_legacy_identity.dart';
import 'package:aid_habitat_app/services/offline_vault.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const patient = 'nocodb-beneficiaire-synthetic';
const dossier = 'synthetic-dossier';
const tab = 'Contexte de vie-Médical';
const revision = '00000000-0000-4000-8000-000000000011';
const writeId = '00000000-0000-4000-8000-000000000012';
Map<String, dynamic> remote(int page) => {
  'patientId': patient,
  'dossierId': dossier,
  'scopeType': 'dossier_detail',
  'scopeId': patient,
  'tabKey': tab,
  'pageNumber': page,
  'subTabKey': '',
  'revision': revision,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('only exact legacy revision and full identity can repair routing', () {
    bool accepts(Map<String, dynamic> value) => matchesLegacyNoteIdentity(
      remote: value,
      patientId: patient,
      dossierId: dossier,
      scopeType: 'dossier_detail',
      tabKey: tab,
      pageNumber: 0,
      expectedRevision: revision,
    );
    expect(accepts(remote(0)), isTrue);
    for (final key in [
      'patientId',
      'dossierId',
      'scopeType',
      'scopeId',
      'tabKey',
      'subTabKey',
      'pageNumber',
      'revision',
    ]) {
      expect(accepts({...remote(0), key: 'other'}), isFalse, reason: key);
    }
  });
  test('independent notes never switch away from their canonical dossier', () {
    for (final key in ['Bénéficiaire-Notes', 'notes_rapides']) {
      expect(
        matchesLegacyNoteIdentity(
          remote: {...remote(0), 'tabKey': key},
          patientId: patient,
          dossierId: dossier,
          scopeType: 'dossier_detail',
          tabKey: key,
          pageNumber: 0,
          expectedRevision: revision,
        ),
        isFalse,
      );
    }
  });
  test(
    'four missing-page conflicts repair only address, preserving all contents and revision',
    () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      await db.insert('app_session', {
        'id': 1,
        'user_local_id': 'owner',
        'created_at': '2026-10-05',
        'updated_at': '2026-10-05',
      });
      final notes = NoteRepository(database: local);
      final sync = SyncRepository(databaseProvider: () async => db);
      for (var page = 0; page < 4; page++) {
        final id = 'note_${patient}_${tab}_$page';
        final op = 'sync_$id';
        final drawing = jsonEncode({
          'text': 'synthetic $page',
          'strokes': [
            {'x': page},
          ],
        });
        await notes.saveDrawingJson(
          patientId: patient,
          dossierId: dossier,
          tabKey: tab,
          pageNumber: page,
          drawingJson: drawing,
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
        final payload = <String, dynamic>{
          'patientLocalId': patient,
          'dossierId': dossier,
          'tabKey': tab,
          'pageNumber': page,
          'drawingJson': drawing,
          'textContent': 'keep',
          'previewDataUrl': 'keep-preview',
          'expectedRevision': revision,
          'writeId': writeId,
          'conflict': {
            'remote': {'error': 'NOTE_PAGE_RECORD_MISSING'},
          },
        };
        await db.update(
          'sync_operations',
          {'payload_json': jsonEncode(payload), 'status': 'conflict'},
          where: 'id = ?',
          whereArgs: [op],
        );
        await db.update(
          'note_pages',
          {'remote_revision': revision, 'sync_state': 'conflict'},
          where: 'local_id = ?',
          whereArgs: [id],
        );
        final before = await db.query(
          'sync_operations',
          where: 'id = ?',
          whereArgs: [op],
        );
        expect(
          await sync.repairMissingNoteIdentity(
            op,
            writeId: 'stale-local-write',
            remote: remote(page),
          ),
          isFalse,
        );
        expect(
          await sync.repairMissingNoteIdentity(
            op,
            writeId: writeId,
            remote: {...remote(page), 'revision': 'other'},
          ),
          isFalse,
        );
        expect(
          await db.query('sync_operations', where: 'id = ?', whereArgs: [op]),
          before,
        );
        await db.update('app_session', {'user_local_id': 'other'});
        expect(
          await sync.repairMissingNoteIdentity(
            op,
            writeId: writeId,
            remote: remote(page),
          ),
          isFalse,
        );
        await db.update('app_session', {'user_local_id': 'owner'});
        expect(
          await sync.repairMissingNoteIdentity(
            op,
            writeId: writeId,
            remote: remote(page),
          ),
          isTrue,
        );
        final queued = (await db.query(
          'sync_operations',
          where: 'id = ?',
          whereArgs: [op],
        )).single;
        final after = jsonDecode(
          await OfflineVault.instance.openString(
            queued['payload_json'] as String,
          ),
        );
        expect(after, {
          ...payload..remove('conflict'),
          'scopeType': 'dossier_detail',
          'scopeId': patient,
        });
        expect(queued['status'], 'pending');
        final note = (await db.query(
          'note_pages',
          where: 'local_id = ?',
          whereArgs: [id],
        )).single;
        expect(
          await OfflineVault.instance.openString(
            note['drawing_json'] as String,
          ),
          drawing,
        );
        expect(note['remote_revision'], revision);
        expect(
          await sync.repairMissingNoteIdentity(
            op,
            writeId: writeId,
            remote: remote(page),
          ),
          isFalse,
        );
        // A subsequent autosave retains the corrected address, including clears.
        await notes.saveDrawingJson(
          patientId: patient,
          dossierId: dossier,
          tabKey: tab,
          pageNumber: page,
          drawingJson: '{"text":"","strokes":[]}',
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
        final latest = (await db.query(
          'sync_operations',
          where: 'id = ?',
          whereArgs: [op],
        )).single;
        final latestPayload = jsonDecode(
          await OfflineVault.instance.openString(
            latest['payload_json'] as String,
          ),
        );
        expect(latestPayload['scopeId'], patient);
        expect(latestPayload['expectedRevision'], revision);
        expect(latestPayload['drawingJson'], '{"text":"","strokes":[]}');
      }
    },
  );
}
