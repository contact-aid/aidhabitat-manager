import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import 'local_database.dart';
import 'nocodb_api_client.dart';
import 'offline_vault.dart';
import 'sync_operation_ownership.dart';

/// A recovery copy is independent of sync: it never changes queue or note rows.
class NoteBackupService {
  NoteBackupService({
    Future<Database> Function()? databaseProvider,
    NocodbApiClient? apiClient,
  }) : _databaseProvider =
           databaseProvider ?? (() => LocalDatabase.instance.database),
       _apiClient = apiClient ?? NocodbApiClient();
  final Future<Database> Function() _databaseProvider;
  final NocodbApiClient _apiClient;

  Future<Map<String, dynamic>> backupOperation(String operationId) async {
    final scope = SyncSessionScope();
    return scope.run(() async {
      final snapshot = await readSnapshot(operationId);
      scope.check();
      final patientId =
          (snapshot['payload'] as Map)['patientLocalId'] as String;
      final json = jsonEncode(snapshot);
      final bytes = utf8.encode(json);
      if (bytes.length > 20 * 1024 * 1024) {
        throw StateError(
          'La copie dépasse la capacité de sauvegarde par opération.',
        );
      }
      final expectedHash = sha256.convert(bytes).toString();
      final receipt = await _apiClient.backupNoteSnapshot(
        patientId: patientId,
        snapshotJson: json,
      );
      _verifyReceipt(receipt, expectedHash, bytes.length);
      scope.check();
      // Check the retrieval path as well as the write response. No sync ACK.
      final recovered = await _apiClient.readNoteBackupContent(
        receipt['backupId'] as String,
      );
      scope.check();
      if (recovered['patientId'] != patientId ||
          recovered['snapshotJson'] != json ||
          recovered['receipt'] is! Map) {
        throw StateError(
          'La relecture de la sauvegarde ne correspond pas à la copie envoyée.',
        );
      }
      final rereadReceipt = (recovered['receipt'] as Map)
          .cast<String, dynamic>();
      _verifyReceipt(rereadReceipt, expectedHash, bytes.length);
      if (rereadReceipt['backupId'] != receipt['backupId']) {
        throw StateError('Le reçu de sauvegarde ne correspond pas.');
      }
      return receipt;
    });
  }

  void _verifyReceipt(Map<String, dynamic> receipt, String hash, int bytes) {
    if (receipt['storedVerified'] != true ||
        receipt['sha256'] != hash ||
        receipt['bytes'] != bytes ||
        receipt['source'] != 'local-operation' ||
        receipt['backupId'] is! String ||
        (receipt['backupId'] as String).isEmpty) {
      throw StateError('La sauvegarde distante n’a pas pu être vérifiée.');
    }
  }

  /// Authorized, consistent local snapshot. Both queued and current versions
  /// are included even when their drawings differ. No token or vault key.
  Future<Map<String, dynamic>> readSnapshot(String operationId) async {
    final db = await _databaseProvider();
    return db.transaction((txn) async {
      final owned = await txn.rawQuery(
        '''SELECT operation.*
        FROM sync_operations AS operation
        JOIN sync_operation_ownership AS ownership ON ownership.operation_id=operation.id
        JOIN app_session AS session ON session.id=1
          AND session.user_local_id=ownership.owner_user_local_id
        WHERE operation.id=? AND operation.entity_type='note_page'
          AND operation.status!='completed'
          AND ownership.attribution_state IN (?, ?)''',
        [
          operationId,
          SyncOperationOwnership.capturedAtEnqueue,
          SyncOperationOwnership.reviewed,
        ],
      );
      if (owned.length != 1) {
        throw StateError(
          'Cette opération n’est pas accessible pour ce compte.',
        );
      }
      final op = owned.single;
      final raw = await OfflineVault.instance.openString(
        op['payload_json'] as String,
      );
      final payload = jsonDecode(raw);
      if (payload is! Map<String, dynamic> ||
          payload['drawingJson'] is! String ||
          payload['patientLocalId'] is! String ||
          (payload['patientLocalId'] as String).isEmpty) {
        throw const FormatException('Copie locale de note illisible.');
      }
      final rows = await txn.query(
        'note_pages',
        where: 'local_id=?',
        whereArgs: [op['entity_local_id']],
      );
      Map<String, dynamic>? note;
      if (rows.isNotEmpty) {
        if (rows.length != 1 ||
            rows.single['patient_local_id'] != payload['patientLocalId']) {
          throw StateError('L’identité de la note locale ne correspond pas.');
        }
        note = Map<String, dynamic>.from(rows.single);
        for (final field in ['drawing_json', 'text_content']) {
          note[field] = await OfflineVault.instance.openNullableString(
            note[field] as String?,
          );
        }
        note['drawingJson'] = note.remove('drawing_json') ?? '';
        note['textContent'] = note.remove('text_content') ?? '';
      }
      return {
        'schemaVersion': 1,
        'operationId': op['id'],
        'entityType': 'note_page',
        'entityLocalId': op['entity_local_id'],
        'operationType': op['operation_type'],
        'payload': payload,
        'localNote': note,
        'status': op['status'],
        'attemptCount': op['attempt_count'],
        'lastError': op['last_error'],
        'createdAt': op['created_at'],
        'updatedAt': op['updated_at'],
      };
    });
  }
}
