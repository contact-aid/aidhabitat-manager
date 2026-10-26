import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// Opt-in only: an existing queue is never enrolled by an application upgrade.
/// A visit is identified by its scheduled date, not by a network connection.
class HousingVisitHandoff {
  static const protocol = 'housing-visit-v1';
  static String _key(String dossierId) => 'housing_visit_handoff:$dossierId';

  static Future<Map<String, dynamic>?> read(
    DatabaseExecutor db,
    String dossierId,
  ) async {
    final rows = await db.query(
      'kv_store',
      where: 'key = ?',
      whereArgs: [_key(dossierId)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return (jsonDecode(rows.single['value'] as String) as Map)
        .cast<String, dynamic>();
  }

  static Future<void> begin(
    DatabaseExecutor db,
    String dossierId,
    String? visitDate,
    DateTime now,
  ) async {
    final date = DateTime.tryParse(visitDate ?? '');
    if (date == null) return;
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    // Opening a historical report is not starting another visit.
    if (day != today) return;
    final visitKey = day.toIso8601String().substring(0, 10);
    final existing = await read(db, dossierId);
    if (existing?['visitKey'] == visitKey) return;
    final dossiers = await db.query(
      'dossiers',
      columns: ['housing_local_id'],
      where: 'local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (dossiers.isEmpty) return;
    final pending = await db.query(
      'sync_operations',
      columns: ['id'],
      where:
          "entity_type = 'housing' AND (entity_local_id = ? OR entity_local_id = ?) AND status != 'completed'",
      whereArgs: [dossierId, dossiers.single['housing_local_id']],
      limit: 1,
    );
    if (pending.isNotEmpty) return;
    await _write(db, dossierId, {'visitKey': visitKey, 'phase': 'first'});
  }

  static Future<void> settle(
    DatabaseExecutor db,
    String dossierId,
    Object? marker,
  ) async {
    if (marker is! Map || marker['visitKey'] is! String) return;
    final current = await read(db, dossierId);
    if (current?['visitKey'] != marker['visitKey']) return;
    await _write(db, dossierId, {...current!, 'phase': 'normal'});
  }

  static Future<bool> claim(
    Database db,
    String id,
    Object? marker,
    String writeId,
  ) => db.transaction((txn) async {
    final state = await read(txn, id);
    if (marker is! Map ||
        marker['phase'] != 'first' ||
        state?['visitKey'] != marker['visitKey'] ||
        state?['phase'] != 'first') {
      return false;
    }
    // Persist BEFORE sending. An uncertain response must never authorize a
    // later retry to overwrite a web correction.
    await _write(txn, id, {
      ...state!,
      'phase': 'attempted',
      'writeId': writeId,
    });
    return true;
  });

  static Future<void> rejected(Database db, String id, String writeId) =>
      db.transaction((txn) async {
        final state = await read(txn, id);
        if (state?['phase'] == 'attempted' && state?['writeId'] == writeId) {
          await _write(txn, id, {...state!, 'phase': 'rejected'});
        }
      });

  static Future<bool> mayPreferVisit(
    DatabaseExecutor db,
    String id,
    Map<String, dynamic> payload,
  ) async {
    final marker = payload['housingVisit'];
    final guard = payload['concurrency'];
    if (marker is! Map ||
        guard is! Map ||
        marker['phase'] != 'first' ||
        guard['housingPolicy'] != protocol) {
      return false;
    }
    final state = await read(db, id);
    return state?['visitKey'] == marker['visitKey'] &&
        state?['phase'] == 'rejected' &&
        state?['writeId'] == guard['writeId'];
  }

  static Future<void> _write(
    DatabaseExecutor db,
    String id,
    Map<String, dynamic> state,
  ) => db
      .insert('kv_store', {
        'key': _key(id),
        'value': jsonEncode(state),
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace)
      .then((_) {});
}
