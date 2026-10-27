import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'local_database.dart';
import 'offline_vault.dart';

Future<void> createVisitAssistantSchema(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE IF NOT EXISTS visit_recordings (
    id TEXT PRIMARY KEY, owner TEXT NOT NULL, dossier_id TEXT NOT NULL,
    payload TEXT NOT NULL, updated_at TEXT NOT NULL)''');
  await db.execute(
    '''CREATE TABLE IF NOT EXISTS visit_ai_receipts (
    receipt TEXT PRIMARY KEY, dossier_id TEXT NOT NULL, applied_at TEXT NOT NULL)''',
  );
}

class VisitAssistantStore {
  VisitAssistantStore({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;
  final LocalDatabase _database;
  Future<void> save(Map<String, dynamic> job) async {
    final db = await _database.database;
    await db.insert('visit_recordings', {
      'id': job['id'],
      'owner': job['owner'],
      'dossier_id': job['dossierId'],
      'payload': await OfflineVault.instance.sealString(jsonEncode(job)),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> list(
    String owner, {
    String? dossierId,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'visit_recordings',
      where: 'owner = ?${dossierId == null ? '' : ' AND dossier_id = ?'}',
      whereArgs: [owner, if (dossierId != null) dossierId],
      orderBy: 'updated_at DESC',
    );
    return Future.wait(
      rows.map(
        (row) async =>
            jsonDecode(
                  await OfflineVault.instance.openString(
                    row['payload'] as String,
                  ),
                )
                as Map<String, dynamic>,
      ),
    );
  }
}
