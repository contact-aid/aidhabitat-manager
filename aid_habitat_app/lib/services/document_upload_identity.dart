import 'dart:convert';

import 'package:sqflite/sqflite.dart';

String documentUploadIdentityKey(String patientId, String localId) =>
    'document_upload_identity:${jsonEncode([patientId, localId])}';

Future<String?> readDocumentUploadIdentity(
  DatabaseExecutor db,
  String patientId,
  String localId,
) async {
  final rows = await db.query(
    'kv_store',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [documentUploadIdentityKey(patientId, localId)],
    limit: 1,
  );
  final value = rows.isEmpty ? '' : rows.single['value'] as String? ?? '';
  return value.isEmpty ? null : value;
}

Future<void> storeDocumentUploadIdentity(
  DatabaseExecutor db,
  String patientId,
  String localId,
  String clientId,
) async {
  if (clientId.isEmpty) return;
  await db.insert('kv_store', {
    'key': documentUploadIdentityKey(patientId, localId),
    'value': clientId,
    'updated_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// Recover the server identity for documents imported by older clients.
/// A missing or ambiguous binding must never turn a replacement into a create.
String resolveImportedDocumentUploadIdentity(
  List<Map<String, dynamic>> documents,
  Iterable<String> urls,
) {
  String path(String value) => Uri.tryParse(value)?.path ?? '';
  final paths = urls.map(path).where((value) => value.isNotEmpty).toSet();
  final matches = documents
      .where(
        (doc) => [
          'remotePath',
          'publicUrl',
        ].any((key) => paths.contains(path(doc[key]?.toString() ?? ''))),
      )
      .toList();
  if (matches.length != 1) {
    throw StateError('Identite du document distant non confirmee');
  }
  final clientId = matches.single['clientDocumentId']?.toString().trim() ?? '';
  if (clientId.isEmpty) {
    throw StateError('Identite de remplacement du document absente');
  }
  return clientId;
}
