import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/types.dart';
import 'local_database.dart';
import 'offline_vault.dart';
import 'sync_operation_ownership.dart';
import 'sync_mutation.dart';

const Set<String> _kReportPrerequisiteEntityTypes = {
  'dossier',
  'patient',
  'housing',
  'document',
  'note_page',
  'contexte_de_vie',
  'diagnostic_sanitaires',
  'mesures_anthropometriques',
  'observations_synthese',
  'visit_recommendations',
};

class _SyncDatabaseHandle {
  const _SyncDatabaseHandle(this._provider);

  final Future<Database> Function() _provider;

  Future<Database> get database => _provider();
}

class SyncRepository {
  SyncRepository({
    LocalDatabase? database,
    Future<Database> Function()? databaseProvider,
  }) : _enforceOwnership = true,
       _database = _SyncDatabaseHandle(
         databaseProvider ??
             () => (database ?? LocalDatabase.instance).database,
       );

  final _SyncDatabaseHandle _database;
  final bool _enforceOwnership;

  /// For focused persistence tests that deliberately have no authentication.
  @visibleForTesting
  SyncRepository.forTesting({
    LocalDatabase? database,
    Future<Database> Function()? databaseProvider,
  }) : _enforceOwnership = false,
       _database = _SyncDatabaseHandle(
         databaseProvider ??
             () => (database ?? LocalDatabase.instance).database,
       );

  Future<int> countConflictingOperations() async {
    final db = await _database.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM sync_operations WHERE status = 'conflict'",
          ),
        ) ??
        0;
  }

  Future<List<SyncOperation>> fetchRunnableOperations({
    bool includePayloads = true,
  }) async {
    final db = await _database.database;
    // Read metadata for unconfirmed operations to preserve per-entity order.
    // Seules les opérations `pending` sont directement exécutables.
    // Les échecs transitoires sont explicitement réhabilités en `pending`
    // par `rehabilitateTransientFailures()` avant chaque cycle. Les échecs
    // permanents restent donc conservés et visibles sans être rejoués en
    // boucle ni supprimés.
    //
    // ⚠️ On EXCLUT `payload_json` du SELECT initial pour éviter les
    // OOM (out-of-memory) sur iPad. Quand l'utilisateur a accumulé
    // plusieurs ops `upload_file` stuck (chacune avec un dataUrl base64
    // de plusieurs MB dans payload_json), un SELECT * chargeait tout
    // en RAM → SqliteException(7) : out of memory. Reporté
    // 2026-04-29 : « SqfliteFfiException(sqlite_error: 7, out of
    // memory) … SELECT * FROM sync_operations WHERE status IN (?, ?) ».
    // The sync worker requests metadata only, then loads one active payload.
    final rows = await db.query(
      'sync_operations',
      columns: const [
        'id',
        'entity_type',
        'entity_local_id',
        'operation_type',
        'status',
        'attempt_count',
        'last_error',
        'created_at',
        'updated_at',
      ],
      where: 'status != ?',
      whereArgs: [SyncOperationStatus.completed.name],
      orderBy: 'created_at ASC, id ASC',
    );

    final now = DateTime.now();
    final eligibleRows = <Map<String, Object?>>[];
    final blockedEntities = <String>{};
    for (final row in rows) {
      final key = '${row['entity_type']}:${row['entity_local_id']}';
      if (blockedEntities.contains(key)) continue;
      if (row['status'] != SyncOperationStatus.pending.name) {
        blockedEntities.add(key);
        continue;
      }
      if (_enforceOwnership &&
          !await SyncOperationOwnership.mayClaim(db, row['id'] as String)) {
        blockedEntities.add(key);
        continue;
      }
      // Une génération PDF différée ne doit jamais doubler les écritures
      // locales encore en file. Le serveur lit NocoDB pour construire le PDF :
      // si un upload photo / une note / une saisie dossier est encore pending
      // ou en backoff, lancer le rapport maintenant produit un PDF incomplet
      // ou un retry trompeur ("connexion lente"). On ne rend les rapports
      // exécutables que lorsque la file d'écritures est vide.
      if (row['entity_type'] == 'report_generation') {
        final dossierId = row['entity_local_id'] as String? ?? '';
        final patientId = await _patientIdForDossier(db, dossierId);
        final blockers = await _countReportPrerequisites(
          db,
          dossierId: dossierId,
          patientId: patientId,
          statuses: const ['pending', 'running', 'failed', 'conflict'],
        );
        if (blockers > 0) continue;
      }
      final attempts = row['attempt_count'] as int? ?? 0;
      final updatedAt = DateTime.tryParse(row['updated_at'] as String? ?? '');
      // Backoff par op dès la 1ère tentative échouée. Evite la boucle
      // tight "échec transitoire → retry immédiat → échec → …" sur les
      // ops qui cassent le sync cycle. Progression : attempts=1→10s,
      // attempts=2→30s, attempts=3→60s, attempts=4→120s, capé à 5 min.
      if (attempts >= 1 && updatedAt != null) {
        final backoffSeconds = _computeOpBackoffSeconds(attempts);
        if (now.difference(updatedAt).inSeconds < backoffSeconds) {
          blockedEntities.add(key);
          continue;
        }
      }
      eligibleRows.add(row);
    }

    // Keep the compatibility loader for callers inspecting queued mutations.
    final out = <SyncOperation>[];
    for (final row in eligibleRows) {
      final id = row['id'] as String;
      final payloadRows = includePayloads
          ? await db.query(
              'sync_operations',
              columns: const ['payload_json'],
              where: 'id = ?',
              whereArgs: [id],
              limit: 1,
            )
          : <Map<String, Object?>>[];
      if (includePayloads && payloadRows.isEmpty) continue;
      final payloadJson = includePayloads
          ? await OfflineVault.instance.openString(
              payloadRows.first['payload_json'] as String,
            )
          : '';
      out.add(
        SyncOperation(
          id: id,
          entityType: row['entity_type'] as String,
          entityLocalId: row['entity_local_id'] as String,
          operationType: row['operation_type'] as String,
          payloadJson: payloadJson,
          status: SyncOperationStatus.values.byName(row['status'] as String),
          attemptCount: row['attempt_count'] as int? ?? 0,
          lastError: row['last_error'] as String?,
          createdAt: DateTime.parse(row['created_at'] as String),
          updatedAt: DateTime.parse(row['updated_at'] as String),
        ),
      );
    }
    return out;
  }

  Future<SyncOperation?> loadRunnablePayload(SyncOperation snapshot) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: const ['payload_json', 'updated_at'],
      where: 'id = ? AND status = ? AND operation_type = ?',
      whereArgs: [snapshot.id, 'pending', snapshot.operationType],
      limit: 1,
    );
    if (rows.isEmpty ||
        DateTime.tryParse(rows.single['updated_at'] as String? ?? '') !=
            snapshot.updatedAt) {
      return null;
    }
    return SyncOperation(
      id: snapshot.id,
      entityType: snapshot.entityType,
      entityLocalId: snapshot.entityLocalId,
      operationType: snapshot.operationType,
      payloadJson: await OfflineVault.instance.openString(
        rows.single['payload_json'] as String,
      ),
      status: snapshot.status,
      attemptCount: snapshot.attemptCount,
      lastError: snapshot.lastError,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
    );
  }

  Future<void> markRunning(String operationId) async {
    await _updateOperation(
      operationId: operationId,
      status: SyncOperationStatus.running,
      clearError: true,
    );
  }

  Future<bool> markPreparationFailure(SyncOperation snapshot) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      if (_enforceOwnership &&
          !await SyncOperationOwnership.mayClaim(txn, snapshot.id)) {
        return false;
      }
      final rows = await txn.query(
        'sync_operations',
        columns: const ['updated_at'],
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? '
            'AND operation_type = ? AND status = ?',
        whereArgs: [
          snapshot.id,
          snapshot.entityType,
          snapshot.entityLocalId,
          snapshot.operationType,
          'pending',
        ],
        limit: 1,
      );
      if (rows.isEmpty ||
          DateTime.tryParse(rows.single['updated_at'] as String) !=
              snapshot.updatedAt) {
        return false;
      }
      final rawUpdatedAt = rows.single['updated_at'];
      final changed = await txn.update(
        'sync_operations',
        {
          'status': 'failed',
          'last_error':
              'Lecture de la sauvegarde locale impossible. '
              'Les données sont conservées ; une vérification est nécessaire.',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ? AND updated_at = ?',
        whereArgs: [snapshot.id, 'pending', rawUpdatedAt],
      );
      if (changed != 1) return false;
      await _updateEntitySyncState(
        db: txn,
        entityType: snapshot.entityType,
        entityLocalId: snapshot.entityLocalId,
        syncState: SyncState.syncError,
      );
      return true;
    });
  }

  /// A queued snapshot may have been replaced while another entity uploaded.
  /// Claim only the exact pending mutation that this worker has loaded.
  Future<bool> tryMarkRunning(SyncOperation operation) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      if (_enforceOwnership &&
          !await SyncOperationOwnership.mayClaim(txn, operation.id)) {
        return false;
      }
      final blockers = await txn.query(
        'sync_operations',
        columns: const ['id'],
        where:
            'entity_type = ? AND entity_local_id = ? AND id != ? '
            'AND status NOT IN (?, ?)',
        whereArgs: [
          operation.entityType,
          operation.entityLocalId,
          operation.id,
          'pending',
          'completed',
        ],
        limit: 1,
      );
      if (blockers.isNotEmpty) return false;
      final rows = await txn.query(
        'sync_operations',
        columns: const ['payload_json', 'updated_at'],
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? '
            'AND operation_type = ? AND status = ?',
        whereArgs: [
          operation.id,
          operation.entityType,
          operation.entityLocalId,
          operation.operationType,
          SyncOperationStatus.pending.name,
        ],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final row = rows.single;
      if (DateTime.tryParse(row['updated_at'] as String? ?? '') !=
          operation.updatedAt) {
        return false;
      }
      final payload = await OfflineVault.instance.openString(
        row['payload_json'] as String,
      );
      if (payload != operation.payloadJson) return false;
      await txn.update(
        'sync_operations',
        {
          'status': SyncOperationStatus.running.name,
          'last_error': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [operation.id],
      );
      return true;
    });
  }

  /// Marque une op comme `completed` UNIQUEMENT si elle est encore
  /// `running`. Si entre temps l'utilisateur a tapé d'autres caractères
  /// (donc `dossier_repository.updatePatient` a fait `INSERT(replace)`
  /// sur la même `id`, ce qui repasse le row à `pending` avec un
  /// nouveau payload), la transition est rejetée → le row reste
  /// `pending` avec sa payload fraîche, le SyncEngine la repushera au
  /// prochain cycle, et l'utilisateur ne perd PAS sa frappe. C'est le
  /// fix de la race « Bro → B » (avril 2026).
  Future<bool> markCompleted({
    required String operationId,
    required String entityType,
    required String entityLocalId,
  }) => _markCompleted(
    operationId: operationId,
    entityType: entityType,
    entityLocalId: entityLocalId,
  );

  Future<bool> markCompletedForPayload(SyncOperation operation) =>
      _markCompleted(
        operationId: operation.id,
        entityType: operation.entityType,
        entityLocalId: operation.entityLocalId,
        expectedPayloadJson: operation.payloadJson,
      );

  Future<bool> acknowledgeVersionedMutation(
    SyncOperation operation,
    String? version, {
    String? remoteEntityId,
  }) => _markCompleted(
    operationId: operation.id,
    entityType: operation.entityType,
    entityLocalId: operation.entityLocalId,
    expectedPayloadJson: operation.payloadJson,
    acknowledgedVersion: version,
    acknowledgedRemoteEntityId: remoteEntityId,
  );

  Future<bool> acknowledgeNotePageMutation(
    SyncOperation operation, {
    required String revision,
    required String remotePath,
    required String remoteUrl,
  }) => _markCompleted(
    operationId: operation.id,
    entityType: operation.entityType,
    entityLocalId: operation.entityLocalId,
    expectedPayloadJson: operation.payloadJson,
    acknowledgedVersion: revision,
    acknowledgedRemotePath: remotePath,
    acknowledgedRemoteUrl: remoteUrl,
  );

  Future<bool> _markCompleted({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    String? expectedPayloadJson,
    String? acknowledgedVersion,
    String? acknowledgedRemoteEntityId,
    String? acknowledgedRemotePath,
    String? acknowledgedRemoteUrl,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      if (expectedPayloadJson != null) {
        final rows = await txn.query(
          'sync_operations',
          columns: const ['payload_json', 'status'],
          where: 'id = ? AND entity_type = ? AND entity_local_id = ?',
          whereArgs: [operationId, entityType, entityLocalId],
          limit: 1,
        );
        if (rows.isEmpty) return false;
        final currentPayload = await OfflineVault.instance.openString(
          rows.single['payload_json'] as String,
        );
        final expected =
            jsonDecode(expectedPayloadJson) as Map<String, dynamic>;
        final retry = expected['retryMutation'];
        if (rows.single['status'] != 'running' ||
            currentPayload != expectedPayloadJson ||
            retry is Map) {
          if ((rows.single['status'] == 'pending' ||
                  (rows.single['status'] == 'running' &&
                      currentPayload == expectedPayloadJson)) &&
              acknowledgedVersion != null) {
            final pending = jsonDecode(currentPayload) as Map<String, dynamic>;
            final rebased = entityType == 'note_page'
                ? rebaseAcknowledgedNoteMutation(
                    sent: expected,
                    pending: pending,
                    revision: acknowledgedVersion,
                  )
                : rebaseAcknowledgedMutation(
                    sent: retry is Map
                        ? retry.cast<String, dynamic>()
                        : expected,
                    pending: pending,
                    version: acknowledgedVersion,
                  );
            if (rebased != null) {
              await txn.update(
                'sync_operations',
                {
                  'payload_json': await OfflineVault.instance.sealString(
                    jsonEncode(rebased),
                  ),
                  'status': 'pending',
                  'updated_at': DateTime.now().toIso8601String(),
                },
                where: 'id = ?',
                whereArgs: [operationId],
              );
              await _storeEntityVersion(
                txn,
                entityType,
                entityLocalId,
                acknowledgedVersion,
                remoteEntityId: acknowledgedRemoteEntityId,
                remotePath: acknowledgedRemotePath,
                remoteUrl: acknowledgedRemoteUrl,
              );
            }
          }
          return false;
        }
      }
      if (acknowledgedVersion != null) {
        await _storeEntityVersion(
          txn,
          entityType,
          entityLocalId,
          acknowledgedVersion,
          remoteEntityId: acknowledgedRemoteEntityId,
          remotePath: acknowledgedRemotePath,
          remoteUrl: acknowledgedRemoteUrl,
        );
      }
      final updated = await txn.update(
        'sync_operations',
        {
          'status': SyncOperationStatus.completed.name,
          'last_error': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? '
            'AND status = ?',
        whereArgs: [
          operationId,
          entityType,
          entityLocalId,
          SyncOperationStatus.running.name,
        ],
      );
      if (updated == 0) return false;

      // Completing one mutation does not acknowledge the entity's whole queue.
      // Keep this read and the entity update in the same transaction.
      final remaining = await txn.query(
        'sync_operations',
        columns: const ['status'],
        distinct: true,
        where: 'entity_type = ? AND entity_local_id = ? AND status != ?',
        whereArgs: [
          entityType,
          entityLocalId,
          SyncOperationStatus.completed.name,
        ],
      );
      final states = remaining.map((row) => row['status']).toSet();
      final state = states.contains('conflict')
          ? SyncState.conflict
          : states.contains(SyncOperationStatus.failed.name)
          ? SyncState.syncError
          : states.isNotEmpty
          ? SyncState.pendingSync
          : SyncState.synced;
      await _updateEntitySyncState(
        db: txn,
        entityType: entityType,
        entityLocalId: entityLocalId,
        syncState: state,
      );
      return true;
    });
  }

  Future<void> _storeEntityVersion(
    DatabaseExecutor db,
    String type,
    String id,
    String version, {
    String? remoteEntityId,
    String? remotePath,
    String? remoteUrl,
  }) async {
    final table = switch (type) {
      'patient' => 'patients',
      'housing' => 'housings',
      'dossier' => 'dossiers',
      'contexte_de_vie' => 'contexte_de_vie',
      'note_page' => 'note_pages',
      'mesures_anthropometriques' ||
      'observations_synthese' ||
      'diagnostic_sanitaires' => type,
      _ => throw StateError('Unsupported versioned entity: $type'),
    };
    await db.update(
      table,
      type == 'contexte_de_vie'
          ? {'remote_reference_json': version, 'remote_reference_known': 1}
          : type == 'note_page'
          ? {
              'remote_revision': version,
              'drawing_remote_path': remotePath ?? '',
              'drawing_remote_url': remoteUrl ?? '',
            }
          : {
              'remote_updated_at': version,
              if (type == 'housing' && remoteEntityId != null)
                'remote_housing_id': remoteEntityId,
            },
      where: switch (type) {
        'housing' =>
          'local_id IN (SELECT housing_local_id FROM dossiers WHERE local_id = ?)',
        'mesures_anthropometriques' ||
        'observations_synthese' ||
        'contexte_de_vie' ||
        'diagnostic_sanitaires' => 'dossier_local_id = ?',
        _ => 'local_id = ?',
      },
      whereArgs: [id],
    );
  }

  /// Persist a server version only while this exact payload owns the reply.
  /// Entity acknowledgement belongs exclusively to markCompleted's transaction.
  Future<void> storeRemoteUpdatedAt(
    SyncOperation operation,
    String? value,
  ) async {
    if (value == null) return;
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        columns: const ['payload_json'],
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [
          operation.id,
          operation.entityType,
          operation.entityLocalId,
          'running',
        ],
        limit: 1,
      );
      if (rows.isEmpty ||
          await OfflineVault.instance.openString(
                rows.single['payload_json'] as String,
              ) !=
              operation.payloadJson) {
        return;
      }
      final table = switch (operation.entityType) {
        'patient' => 'patients',
        'housing' => 'housings',
        'dossier' => 'dossiers',
        'mesures_anthropometriques' ||
        'observations_synthese' ||
        'diagnostic_sanitaires' => operation.entityType,
        _ => null,
      };
      if (table == null) return;
      await txn.update(
        table,
        {'remote_updated_at': value},
        where: switch (operation.entityType) {
          'housing' =>
            'local_id IN (SELECT housing_local_id FROM dossiers WHERE local_id = ?)',
          'mesures_anthropometriques' ||
          'observations_synthese' ||
          'diagnostic_sanitaires' => 'dossier_local_id = ?',
          _ => 'local_id = ?',
        },
        whereArgs: [operation.entityLocalId],
      );
    });
  }

  /// Marque une op comme `failed` UNIQUEMENT si elle est encore
  /// `running` (cf. `markCompleted` pour le rationale du verrou). Si
  /// l'op a été remplacée par une version `pending` pendant le PATCH en
  /// vol, la transition est rejetée → le row reste `pending` avec sa
  /// payload fraîche, et n'est PAS marqué `failed` (sinon on
  /// déclencherait un bandeau rouge UI alors que la mutation suivante
  /// va potentiellement réussir).
  Future<void> markFailed({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        columns: ['attempt_count'],
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [
          operationId,
          entityType,
          entityLocalId,
          SyncOperationStatus.running.name,
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        // L'op a été remplacée pendant le PATCH — laisser le row `pending`
        // tel quel, il sera retenté au prochain cycle.
        return;
      }
      final attempts = rows.first['attempt_count'] as int? ?? 0;

      final updated = await txn.update(
        'sync_operations',
        {
          'status': SyncOperationStatus.failed.name,
          'attempt_count': attempts + 1,
          'last_error': error,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [operationId, SyncOperationStatus.running.name],
      );
      if (updated == 0) {
        // Race : la transition pending→running a été annulée juste avant
        // notre UPDATE. Identique au cas `rows.isEmpty` ci-dessus.
        return;
      }

      await _updateEntitySyncState(
        db: txn,
        entityType: entityType,
        entityLocalId: entityLocalId,
        syncState: SyncState.syncError,
      );
    });
  }

  /// Backoff par opération après échec transitoire. Progression :
  /// attempts=1→10s, 2→30s, 3→60s, 4→120s, 5+→300s (capé à 5 min).
  /// Appelé uniquement par [fetchRunnableOperations] pour filtrer les
  /// ops qu'il faut laisser reposer.
  static int _computeOpBackoffSeconds(int attempts) {
    if (attempts <= 0) return 0;
    const schedule = [10, 30, 60, 120, 300];
    return schedule[(attempts - 1).clamp(0, schedule.length - 1)];
  }

  /// Total des opérations "en attente" pour affichage UI (bandeau,
  /// compteur) : inclut aussi bien les ops retentables immédiatement
  /// que celles en cours de backoff — l'utilisateur doit voir qu'il y
  /// a encore du travail en file même si rien n'est exécuté tout de
  /// suite. Seules les operations `completed` sont exclues : un envoi en
  /// cours ou un conflit ne doit pas autoriser un rechargement destructif.
  Future<int> countPendingOperations() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM sync_operations '
      'WHERE status != ?',
      [SyncOperationStatus.completed.name],
    );
    if (rows.isEmpty) return 0;
    final v = rows.first['cnt'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  /// Compte uniquement les écritures encore en attente qui alimentent le
  /// rapport de [dossierId]. Une erreur ancienne appartenant à un autre
  /// bénéficiaire ne doit pas empêcher la génération de ce rapport.
  Future<int> countPendingReportPrerequisites({
    required String dossierId,
    required String patientId,
  }) async {
    final db = await _database.database;
    return _countReportPrerequisites(
      db,
      dossierId: dossierId,
      patientId: patientId,
      statuses: const ['pending', 'running', 'failed'],
    );
  }

  /// Même filtre que [countPendingReportPrerequisites], limité aux conflits
  /// qui concernent réellement le rapport demandé.
  Future<int> countConflictingReportPrerequisites({
    required String dossierId,
    required String patientId,
  }) async {
    final db = await _database.database;
    return _countReportPrerequisites(
      db,
      dossierId: dossierId,
      patientId: patientId,
      statuses: const ['conflict'],
    );
  }

  Future<String> _patientIdForDossier(Database db, String dossierId) async {
    if (dossierId.isEmpty) return '';
    final rows = await db.query(
      'dossiers',
      columns: const ['patient_local_id'],
      where: 'local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    return rows.isEmpty
        ? ''
        : (rows.first['patient_local_id']?.toString() ?? '');
  }

  Future<int> _countReportPrerequisites(
    Database db, {
    required String dossierId,
    required String patientId,
    required List<String> statuses,
  }) async {
    if (dossierId.isEmpty || statuses.isEmpty) return 0;

    final resolvedPatientId = patientId.isNotEmpty
        ? patientId
        : await _patientIdForDossier(db, dossierId);
    final statusPlaceholders = List.filled(statuses.length, '?').join(', ');
    final directDossierTypes = _kReportPrerequisiteEntityTypes
        .difference(const {'patient', 'document', 'note_page'})
        .toList(growable: false);
    final typePlaceholders = List.filled(
      directDossierTypes.length,
      '?',
    ).join(', ');

    final rows = await db.rawQuery(
      '''
      SELECT COUNT(*) AS cnt
      FROM sync_operations AS op
      WHERE op.status IN ($statusPlaceholders)
        AND (
          (
            op.entity_type IN ($typePlaceholders)
            AND op.entity_local_id = ?
          )
          OR (
            op.entity_type = 'patient'
            AND op.entity_local_id = ?
          )
          OR (
            op.entity_type = 'note_page'
            AND EXISTS (
              SELECT 1
              FROM note_pages AS note
              WHERE note.local_id = op.entity_local_id
                AND (
                  note.dossier_local_id = ?
                  OR (
                    note.dossier_local_id IS NULL
                    AND note.patient_local_id = ?
                  )
                )
            )
          )
          OR (
            op.entity_type = 'document'
            AND EXISTS (
              SELECT 1
              FROM documents AS document
              WHERE document.local_id = op.entity_local_id
                AND (
                  document.dossier_local_id = ?
                  OR (
                    document.dossier_local_id IS NULL
                    AND document.patient_local_id = ?
                  )
                )
            )
          )
        )
      ''',
      [
        ...statuses,
        ...directDossierTypes,
        dossierId,
        resolvedPatientId,
        dossierId,
        resolvedPatientId,
        dossierId,
        resolvedPatientId,
      ],
    );
    if (rows.isEmpty) return 0;
    final value = rows.first['cnt'];
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse('$value') ?? 0;
  }

  /// Réhabilite les opérations `failed` dont le message d'erreur ressemble
  /// à un problème transitoire (5xx serveur, timeout, déconnexion…) en
  /// les repassant à `pending` pour qu'elles soient retentées. Laisse les
  /// vraies erreurs fonctionnelles (4xx, payload invalide…) en `failed`.
  ///
  /// Appelé au début de chaque cycle de sync pour auto-guérir les
  /// opérations qui se sont accumulées en `failed` à cause d'un hoquet
  /// serveur (notamment les ops de note_page qui ont fait planter la
  /// prod avec des 500 dans le passé).
  ///
  /// **Limite d'âge** : on ne réhabilite QUE les ops créées dans les
  /// 24 dernières heures. Sinon une vieille op `failed` (genre saisie
  /// d'il y a 3 semaines en mode offline qui n'a jamais réussi à
  /// passer) finissait par être repêchée et écrasait NocoDB avec un
  /// payload obsolète — symptôme « le nom revient à une version
  /// antérieure tout seul » signalé le 2026-04-28. Au-delà de 24h, le
  /// payload est considéré comme dépassé : l'utilisateur peut soit
  /// vider la file via `discardFailedOperations` (UI : bouton « Vider
  /// les échecs »), soit refaire la modif manuellement.
  /// Réhabilite les `upload_file` ops `failed` — AGGRESSIVELY (même
  /// pour des erreurs non-transient). Pourquoi ce traitement spécial :
  /// le serveur déduplique les uploads via `documentLocalId` (cf.
  /// `/api/documents` POST côté server/index.mjs), donc un retry est
  /// idempotent — au pire on perd 1 round-trip réseau, jamais de
  /// double-création.
  ///
  /// Cas couverts par ce rehab (vs `rehabilitateTransientFailures`
  /// qui ne match que les patterns d'erreur transient) :
  ///   - 4xx persistants (ex. session expirée, CORS, etc.)
  ///   - SyntaxError, RangeError, parse errors (la 1ère tentative a pu
  ///     se faire avant un fix de schéma)
  ///   - Erreurs non-classifiées
  ///
  /// Limite d'âge : 7 jours (vs 24 h pour le rehab générique). Les
  /// uploads sont du contenu user (photos, rapports) qu'on ne veut
  /// surtout pas perdre par "oubli de retry".
  ///
  /// Appelé automatiquement à chaque ouverture de l'écran Documents
  /// (cf. `data_service.refreshDocumentsFromRemote`) → l'utilisateur
  /// n'a plus jamais à clear le cache pour débloquer un upload bloqué.
  Future<int> rehabFailedDocumentUploads() async {
    final db = await _database.database;
    final ageCutoff = DateTime.now()
        .subtract(const Duration(days: 7))
        .toIso8601String();
    final n = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, updated_at = ?, attempt_count = 0, last_error = NULL
      WHERE status = ?
        AND operation_type = 'upload_file'
        AND created_at > ?
      ''',
      [
        SyncOperationStatus.pending.name,
        DateTime.now().toIso8601String(),
        SyncOperationStatus.failed.name,
        ageCutoff,
      ],
    );
    if (n > 0) {
      // ignore: avoid_print
      print(
        '[sync] rehabFailedDocumentUploads : $n op(s) repassée(s) en pending',
      );
    }
    return n;
  }

  /// Récupère les uploads documents interrompus en plein vol.
  ///
  /// Si l'app est quittée pendant un gros upload, la ligne peut rester en
  /// `running`. Contrairement aux updates métier, l'upload de document est
  /// idempotent côté serveur grâce à `documentLocalId`; le repasser en
  /// `pending` après un délai court est donc sûr et évite une pastille orange
  /// coincée sans retry visible.
  Future<int> recoverInterruptedDocumentUploads({
    Duration maxRunningAge = const Duration(minutes: 2),
  }) async {
    final db = await _database.database;
    final cutoff = DateTime.now().subtract(maxRunningAge).toIso8601String();
    final now = DateTime.now().toIso8601String();
    final recovered = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, attempt_count = 0, last_error = ?, updated_at = ?
      WHERE status = ?
        AND entity_type = 'document'
        AND operation_type = 'upload_file'
        AND updated_at < ?
      ''',
      [
        SyncOperationStatus.pending.name,
        'Upload document récupéré après interruption',
        now,
        SyncOperationStatus.running.name,
        cutoff,
      ],
    );
    if (recovered > 0) {
      // ignore: avoid_print
      print(
        '[sync] recoverInterruptedDocumentUploads : '
        '$recovered op(s) running → pending',
      );
    }
    return recovered;
  }

  Future<int> rehabilitateTransientFailures() async {
    final db = await _database.database;
    final ageCutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .toIso8601String();
    // On reset `attempt_count` à 0 en plus du status. Sinon, après un
    // épisode CORS/Vercel-SSO qui a fait échouer 5+ fois la même op,
    // le backoff (`_computeOpBackoffSeconds`) la maintient en attente
    // pendant 5 minutes — l'utilisateur voit l'op « En attente » sans
    // comprendre qu'elle ne sera pas tentée tout de suite. Réhabiliter
    // c'est admettre que la cause de l'échec est passée, donc un budget
    // de tentatives frais est légitime. Si l'op échoue à nouveau, elle
    // re-démarre le cycle de backoff normal à attempt_count=1.
    final rehabilitated = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, updated_at = ?, attempt_count = 0
      WHERE status = ?
        AND created_at > ?
        AND (
          last_error LIKE '%500%'
          OR last_error LIKE '%502%'
          OR last_error LIKE '%503%'
          OR last_error LIKE '%504%'
          OR last_error LIKE '%timeout%' COLLATE NOCASE
          OR last_error LIKE '%SocketException%'
          OR last_error LIKE '%ClientException%'
          OR last_error LIKE '%HttpException%'
          OR last_error LIKE '%HandshakeException%'
          OR last_error LIKE '%during handshake%' COLLATE NOCASE
          OR last_error LIKE '%TransientRemoteException%'
          OR last_error LIKE '%Remote note sync failed%'
          OR last_error LIKE '%Remote document upload failed%'
          OR last_error LIKE '%Document upload network error%'
          OR last_error LIKE '%network error%' COLLATE NOCASE
          OR last_error LIKE '%XMLHttpRequest error%' COLLATE NOCASE
          OR last_error LIKE '%Failed to fetch%' COLLATE NOCASE
          OR last_error LIKE '%CORS%' COLLATE NOCASE
          OR last_error LIKE '%(401)%'
          OR last_error LIKE '%(403)%'
        )
      ''',
      [
        SyncOperationStatus.pending.name,
        DateTime.now().toIso8601String(),
        SyncOperationStatus.failed.name,
        ageCutoff,
      ],
    );
    return rehabilitated;
  }

  /// Erreur transitoire (timeout, déconnexion, 5xx serveur). L'opération
  /// reste en statut `pending` pour être repêchée au prochain cycle de
  /// sync — PAS de bandeau rouge côté UI, PAS de statut `failed`. On
  /// bump juste `attempt_count` et on trace `last_error` pour le debug.
  Future<void> markTransientFailure({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        columns: ['attempt_count'],
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [
          operationId,
          entityType,
          entityLocalId,
          SyncOperationStatus.running.name,
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        // L'op a été remplacée par une version `pending` plus récente
        // pendant le PATCH en vol — ne pas écraser. La nouvelle version
        // contient déjà la donnée la plus récente et sera retentée.
        return;
      }
      final attempts = rows.first['attempt_count'] as int? ?? 0;

      final updated = await txn.update(
        'sync_operations',
        {
          'status': SyncOperationStatus.pending.name,
          'attempt_count': attempts + 1,
          'last_error': error,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [operationId, SyncOperationStatus.running.name],
      );
      if (updated == 0) {
        return;
      }

      // On laisse sync_state sur `pendingSync` (c'est le statut "en cours
      // de sync" normal) plutôt que `syncError` pour ne pas alarmer l'UI.
      await _updateEntitySyncState(
        db: txn,
        entityType: entityType,
        entityLocalId: entityLocalId,
        syncState: SyncState.pendingSync,
      );
    });
  }

  Future<bool> markConflict({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
    required String expectedPayloadJson,
    Map<String, dynamic>? remoteData,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [operationId, entityType, entityLocalId, 'running'],
      );
      if (rows.isEmpty) return false;
      final currentPayload = await OfflineVault.instance.openString(
        rows.single['payload_json'] as String,
      );
      if (currentPayload != expectedPayloadJson) return false;
      final payload = jsonDecode(currentPayload) as Map<String, dynamic>;
      payload['conflict'] = {
        'remote': remoteData,
        'detectedAt': DateTime.now().toIso8601String(),
      };
      final updated = await txn.update(
        'sync_operations',
        {
          'status': 'conflict',
          'payload_json': await OfflineVault.instance.sealString(
            jsonEncode(payload),
          ),
          'last_error': error,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [
          operationId,
          entityType,
          entityLocalId,
          SyncOperationStatus.running.name,
        ],
      );
      if (updated == 0) {
        // L'op a été remplacée pendant le PATCH par une version `pending`
        // plus récente — la nouvelle version va re-PATCHer avec la
        // dernière donnée locale et résoudra (ou pas) le conflit serveur
        // de son côté. Ne pas marquer l'entité en `conflict` ici : on
        // ferait clignoter l'UI à tort.
        return false;
      }

      await _updateEntitySyncState(
        db: txn,
        entityType: entityType,
        entityLocalId: entityLocalId,
        syncState: SyncState.conflict,
      );
      return true;
    });
  }

  Future<void> storeDocumentRemoteData({
    required String operationId,
    required String documentLocalId,
    required String remotePath,
    required String publicUrl,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final previous = await txn.query(
        'documents',
        columns: ['remote_file_path', 'remote_public_url'],
        where: 'local_id = ?',
        whereArgs: [documentLocalId],
        limit: 1,
      );
      final changed = await txn.update(
        'documents',
        {
          'remote_file_path': remotePath,
          'remote_public_url': publicUrl,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where:
            'local_id = ? AND pending_delete = 0 '
            'AND EXISTS (SELECT 1 FROM sync_operations '
            'WHERE id = ? AND entity_type = ? AND entity_local_id = ? '
            'AND operation_type = ? AND status = ?) '
            'AND NOT EXISTS (SELECT 1 FROM sync_operations '
            'WHERE id != ? AND entity_type = ? AND entity_local_id = ? '
            'AND operation_type = ? AND status != ?)',
        whereArgs: [
          documentLocalId,
          operationId,
          'document',
          documentLocalId,
          'upload_file',
          SyncOperationStatus.running.name,
          operationId,
          'document',
          documentLocalId,
          'upload_file',
          SyncOperationStatus.completed.name,
        ],
      );
      if (changed == 0 || previous.isEmpty) return;
      final oldPath = previous.single['remote_file_path'] as String?;
      final oldUrl = previous.single['remote_public_url'] as String?;
      final retired = <String>{
        if (oldPath != null && oldPath.isNotEmpty && oldPath != remotePath)
          oldPath,
        if (oldUrl != null && oldUrl.isNotEmpty && oldUrl != publicUrl) oldUrl,
      };
      if (retired.isEmpty) return;
      // Content URLs are immutable. Retain replaced identities atomically with
      // the ACK so delayed pulls cannot reinstall them after the queue completes.
      final key = 'document_retired_content:$documentLocalId';
      final markers = await txn.query(
        'kv_store',
        where: 'key = ?',
        whereArgs: [key],
        limit: 1,
      );
      if (markers.isNotEmpty) {
        retired.addAll(
          (jsonDecode(markers.single['value'] as String) as List)
              .cast<String>(),
        );
      }
      await txn.insert('kv_store', {
        'key': key,
        'value': jsonEncode(retired.toList()),
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> storeNotePageRemoteData({
    required String noteLocalId,
    required String remotePath,
    required String remoteUrl,
    String? revision,
  }) async {
    final db = await _database.database;
    await db.update(
      'note_pages',
      {
        'drawing_remote_path': remotePath,
        'drawing_remote_url': remoteUrl,
        if (revision != null && revision.isNotEmpty)
          'remote_revision': revision,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [noteLocalId],
    );
  }

  Future<void> storeVisitRecommendationsRemoteRevision({
    required String dossierId,
    required String revision,
  }) async {
    final db = await _database.database;
    await db.update(
      'visit_recommendations',
      {
        'remote_revision': revision,
        'remote_snapshot_exists': 1,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// After a successful remote creation, store the remote IDs in the local
  /// database so subsequent updates can reference them.
  Future<void> storeRemoteIds({
    required String patientLocalId,
    required String remotePatientId,
    required String dossierLocalId,
    String? remoteDossierId,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.update(
        'patients',
        {'remote_patient_id': remotePatientId},
        where: 'local_id = ?',
        whereArgs: [patientLocalId],
      );
      if (dossierLocalId.isNotEmpty && remoteDossierId != null) {
        await txn.update(
          'dossiers',
          {'remote_dossier_id': remoteDossierId},
          where: 'local_id = ?',
          whereArgs: [dossierLocalId],
        );
      }
      // The create reply acknowledges initial values, not later local edits.
      // It supplies identities only; never invent a remote clock from now().
      for (final entity in ['patient', 'housing']) {
        final localId = entity == 'patient' ? patientLocalId : dossierLocalId;
        final remaining = await txn.query(
          'sync_operations',
          columns: ['status'],
          where: 'entity_type = ? AND entity_local_id = ? AND status != ?',
          whereArgs: [entity, localId, 'completed'],
        );
        final states = remaining.map((row) => row['status']).toSet();
        final state = states.contains('conflict')
            ? SyncState.conflict
            : states.contains('failed')
            ? SyncState.syncError
            : states.isNotEmpty
            ? SyncState.pendingSync
            : SyncState.synced;
        await _updateEntitySyncState(
          db: txn,
          entityType: entity,
          entityLocalId: localId,
          syncState: state,
        );
      }
    });
  }

  /// Look up the remote patient ID for a given local patient ID.
  Future<String?> resolveRemotePatientId(String patientLocalId) async {
    final db = await _database.database;
    final rows = await db.query(
      'patients',
      columns: ['remote_patient_id'],
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['remote_patient_id'] as String?;
  }

  /// Look up the remote dossier id (`uuid_source` NocoDB) for a given
  /// local dossier id (`local_*`). Renvoie `null` si le dossier n'a
  /// pas encore été synchronisé côté serveur (créé offline mais
  /// `dossier:create` pas encore complété). Utilisé par
  /// `_processDossierOperation` (update branch) pour traduire le
  /// `local_*` en `uuid_source` avant le PUT — sinon le serveur reçoit
  /// un id qu'il ne reconnaît pas et renvoie 404 → "Load failed"
  /// côté iPad PWA (rapporté 2026-05-04).
  Future<String?> resolveRemoteDossierId(String dossierLocalId) async {
    final db = await _database.database;
    final rows = await db.query(
      'dossiers',
      columns: ['remote_dossier_id'],
      where: 'local_id = ?',
      whereArgs: [dossierLocalId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final remoteId = rows.first['remote_dossier_id'] as String?;
    if (remoteId == null || remoteId.isEmpty) return null;
    return remoteId;
  }

  /// Delete completed sync operations older than [maxAge] to prevent
  /// unbounded SQLite growth. Safe to call periodically.
  Future<int> purgeCompleted({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final db = await _database.database;
    final cutoff = DateTime.now().subtract(maxAge).toIso8601String();
    return db.transaction((txn) async {
      if (_enforceOwnership) {
        await txn.rawDelete(
          '''DELETE FROM ${SyncOperationOwnership.tableName}
             WHERE operation_id IN (
               SELECT id FROM sync_operations
               WHERE status = ? AND updated_at < ?
             )''',
          [SyncOperationStatus.completed.name, cutoff],
        );
      }
      return txn.delete(
        'sync_operations',
        where: 'status = ? AND updated_at < ?',
        whereArgs: [SyncOperationStatus.completed.name, cutoff],
      );
    });
  }

  /// Répare la file au démarrage sans jamais supprimer une donnée utilisateur.
  ///
  /// Les échecs réseau sont réhabilités en `pending`. Une opération restée
  /// `running` après un crash est également remise en attente. Les erreurs
  /// permanentes et les gros payloads restent conservés en `failed` jusqu'à
  /// une action explicite de l'utilisateur.
  ///
  /// Retourne le nombre d'opérations réparées.
  Future<int> purgeStalePendingOperations({
    Duration maxRunningAge = const Duration(hours: 72),
    DateTime? interruptedBefore,
  }) async {
    final db = await _database.database;
    final cutoff = (interruptedBefore ?? DateTime.now().subtract(maxRunningAge))
        .toIso8601String();
    final now = DateTime.now().toIso8601String();
    // 1) Réhabilite les `failed` → `pending` (au lieu de DELETE qui
    //    perdait les modifs offline pour toujours).
    //
    // Exclusion 2026-05-15 : on NE réhabilite PAS les ops dont l'erreur
    // est PERMANENTE — relancer en boucle ne servira à rien. Cas :
    //   - 413 (Content Too Large) : payload trop gros pour Vercel
    //     (limite 4.5 Mo). Ex : photo iPhone brute uploadée avant le
    //     fix de compression — l'op stocke encore le gros payload et
    //     re-foirera à chaque boot tant qu'on ne la jette pas.
    //   - 422 (Unprocessable Entity) : payload malformé / contrainte
    //     NocoDB violée (ex. colonne LongText >100k).
    // Ces ops doivent rester `failed` jusqu'à action utilisateur
    // (Abandonner via le dialog « N opérations en échec » ou refaire
    // la modif depuis l'UI).
    final rehab = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, attempt_count = 0, last_error = NULL, updated_at = ?
      WHERE status = ?
        AND last_error NOT LIKE '%(413)%'
        AND last_error NOT LIKE '%(422)%'
        AND last_error NOT LIKE '%Content Too Large%' COLLATE NOCASE
        AND last_error NOT LIKE '%Payload Too Large%' COLLATE NOCASE
      ''',
      [SyncOperationStatus.pending.name, now, SyncOperationStatus.failed.name],
    );
    if (rehab > 0) {
      // ignore: avoid_print
      print('[sync] boot rehab : $rehab op(s) failed → pending');
    }
    // 2) Un crash peut laisser une op en `running`. Le payload est toujours
    //    la seule copie synchronisable de certaines données (aperçu de note,
    //    document encodé). On la remet en attente au lieu de la supprimer.
    final recovered = await db.rawUpdate(
      '''
      UPDATE sync_operations
      SET status = ?, attempt_count = 0, last_error = ?, updated_at = ?
      WHERE status = ? AND updated_at < ?
      ''',
      [
        SyncOperationStatus.pending.name,
        'Opération récupérée après interruption de la synchronisation',
        now,
        SyncOperationStatus.running.name,
        cutoff,
      ],
    );
    if (recovered > 0) {
      // ignore: avoid_print
      print('[sync] boot recovery : $recovered op(s) running → pending');
    }
    return rehab + recovered;
  }

  Future<void> setEntitySyncState({
    required String entityType,
    required String entityLocalId,
    required SyncState syncState,
  }) async {
    final db = await _database.database;
    await _updateEntitySyncState(
      db: db,
      entityType: entityType,
      entityLocalId: entityLocalId,
      syncState: syncState,
    );
  }

  /// Renvoie un résumé court de la première opération en échec — utilisée
  /// par le bandeau UI pour expliquer à l'utilisateur ce qui bloque.
  /// Renvoie null si aucune op n'est en `failed`.
  Future<Map<String, String?>?> fetchTopFailingOperation() async {
    final db = await _database.database;
    if (_enforceOwnership) {
      final ownership = await SyncOperationOwnership.blockedCounts(db);
      if (ownership.hasActiveSession && ownership.blocksDispatch) {
        return {
          'entityType': 'sync_ownership',
          'lastError':
              ownership.historicalUnattributed +
                      ownership.reviewRequired +
                      ownership.missingOwnership >
                  0
              ? 'Des sauvegardes locales attendent une vérification de leur auteur.'
              : 'Des sauvegardes attendent la reconnexion de leur auteur.',
          'attemptCount': '0',
        };
      }
    }
    final rows = await db.query(
      'sync_operations',
      columns: [
        'id',
        'entity_type',
        'operation_type',
        'entity_local_id',
        'last_error',
        'attempt_count',
      ],
      where: 'status = ?',
      whereArgs: [SyncOperationStatus.failed.name],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return {
      'id': r['id'] as String?,
      'entityType': r['entity_type'] as String?,
      'operationType': r['operation_type'] as String?,
      'entityLocalId': r['entity_local_id'] as String?,
      'lastError': r['last_error'] as String?,
      'attemptCount': '${r['attempt_count'] ?? 0}',
    };
  }

  /// Re-met TOUTES les opérations en `failed` à `pending` (avec
  /// `attempt_count = 0` et `last_error = null`) → débloque la queue
  /// pour un retry immédiat sans attendre le prochain tick. Utilisé
  /// par le bouton « Réessayer maintenant » du dialog d'erreur sync,
  /// quand l'utilisateur juge que l'erreur (typiquement « fetch failed »
  /// transitoire) ne se reproduira pas.
  ///
  /// Renvoie le nombre d'ops re-queue.
  Future<int> resetFailedToPending() async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    return db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'updated_at': now,
      },
      where: 'status = ?',
      whereArgs: [SyncOperationStatus.failed.name],
    );
  }

  /// Liste les erreurs et conflits, sans exposer leur contenu sauvegarde.
  /// par le drawer "ops en échec" pour permettre une action par op
  /// (réessayer / abandonner) au lieu d'un batch global.
  Future<List<Map<String, String?>>> fetchAllFailingOperations() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: [
        'id',
        'entity_type',
        'operation_type',
        'entity_local_id',
        'last_error',
        'attempt_count',
        'updated_at',
        'status',
      ],
      where: 'status IN (?, ?)',
      whereArgs: ['failed', 'conflict'],
      orderBy: 'updated_at DESC',
    );
    return rows.map((r) {
      return {
        'id': r['id'] as String?,
        'entityType': r['entity_type'] as String?,
        'operationType': r['operation_type'] as String?,
        'entityLocalId': r['entity_local_id'] as String?,
        'lastError': r['last_error'] as String?,
        'attemptCount': '${r['attempt_count'] ?? 0}',
        'updatedAt': r['updated_at'] as String?,
        'status': r['status'] as String?,
      };
    }).toList();
  }

  Future<String?> conflictDossierId(String operationId) async {
    final db = await _database.database;
    final operations = await db.query(
      'sync_operations',
      columns: ['entity_type', 'entity_local_id'],
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, 'conflict'],
    );
    if (operations.length != 1) return null;
    final op = operations.single;
    final column = switch (op['entity_type']) {
      'patient' => 'patient_local_id',
      // Unlike 'patient' (whose entity_local_id is the patient's own
      // local_id), 'housing' operations are enqueued with the dossier's
      // local_id directly (cf. `_enqueueEntityUpdate(entityType: 'housing',
      // entityLocalId: dossierId, ...)`) — same as 'dossier' and the
      // secondary entities below. Matching it against `housing_local_id`
      // compared a dossier id against a housing id from two different id
      // spaces, which never matched, so `conflictDossierId` always
      // returned null for a housing conflict and the review screen showed
      // "Comparaison indisponible" no matter what. (2026-09-22)
      'dossier' ||
      'housing' ||
      'contexte_de_vie' ||
      'mesures_anthropometriques' ||
      'observations_synthese' ||
      'diagnostic_sanitaires' => 'local_id',
      _ => null,
    };
    if (column == null) return null;
    final dossiers = await db.query(
      'dossiers',
      columns: ['local_id'],
      where: '$column = ?',
      whereArgs: [op['entity_local_id']],
      limit: 2,
    );
    // Never guess which dossier to review when the binding is ambiguous.
    return dossiers.length == 1 ? dossiers.single['local_id'] as String : null;
  }

  Future<Map<String, dynamic>?> noteConflictDetails(String operationId) async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      columns: const ['entity_type', 'entity_local_id', 'payload_json'],
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, 'conflict'],
      limit: 1,
    );
    if (rows.length != 1 || rows.single['entity_type'] != 'note_page') {
      return null;
    }
    try {
      final payload =
          jsonDecode(
                await OfflineVault.instance.openString(
                  rows.single['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      final tabKey = payload['tabKey']?.toString() ?? '';
      const visitReportTabs = {
        'Bénéficiaire',
        'Contexte de vie',
        'Mesures',
        'Accessibilité',
        'Salle de bain',
        'WC',
        'Préconisations',
      };
      final scopeType = payload['scopeType']?.toString().isNotEmpty == true
          ? payload['scopeType'].toString()
          : tabKey == 'Plans'
          ? 'visit_grid'
          : visitReportTabs.contains(tabKey)
          ? 'visit_report'
          : 'dossier_detail';
      final patientId = payload['patientLocalId']?.toString() ?? '';
      final scopeId = payload['scopeId']?.toString().isNotEmpty == true
          ? payload['scopeId'].toString()
          : payload['dossierId']?.toString().isNotEmpty == true
          ? payload['dossierId'].toString()
          : patientId;
      return {
        'operationId': operationId,
        'noteLocalId': rows.single['entity_local_id'],
        'patientId': patientId,
        'dossierId': payload['dossierId'],
        'scopeType': scopeType,
        'scopeId': scopeId,
        'tabKey': tabKey,
        'pageNumber': payload['pageNumber'] ?? 0,
      };
    } catch (_) {
      return null;
    }
  }

  /// Explicit user choice: keep the complete local note and retry it against
  /// either a freshly fetched revision or the revision observed in the 409
  /// response. This is never automatic for a genuine cross-device conflict.
  Future<bool> resolveNoteConflictKeepingLocal(
    String operationId, {
    String? observedRevision,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        columns: const ['entity_type', 'entity_local_id', 'payload_json'],
        where: 'id = ? AND status = ?',
        whereArgs: [operationId, 'conflict'],
        limit: 1,
      );
      if (rows.length != 1 || rows.single['entity_type'] != 'note_page') {
        return false;
      }
      final payload =
          jsonDecode(
                await OfflineVault.instance.openString(
                  rows.single['payload_json'] as String,
                ),
              )
              as Map<String, dynamic>;
      final revision = observedRevision == null
          ? _noteConflictRevision(payload['conflict'])
          : _noteConflictRevision({'revision': observedRevision});
      if (revision == null) return false;
      payload
        ..remove('conflict')
        ..['expectedRevision'] = revision
        ..['writeId'] = newSyncWriteId()
        ..['predecessorWriteIds'] = <String>[];
      final updated = await txn.update(
        'sync_operations',
        {
          'payload_json': await OfflineVault.instance.sealString(
            jsonEncode(payload),
          ),
          'status': SyncOperationStatus.pending.name,
          'attempt_count': 0,
          'last_error': null,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [operationId, 'conflict'],
      );
      if (updated != 1) return false;
      await txn.update(
        'note_pages',
        {'remote_revision': revision, 'sync_state': SyncState.pendingSync.name},
        where: 'local_id = ?',
        whereArgs: [rows.single['entity_local_id']],
      );
      return true;
    });
  }

  /// Explicit user choice: replace the conflicted local note with the server
  /// snapshot already fetched by the caller, then retire the queued write.
  Future<bool> resolveNoteConflictUsingServer(
    String operationId,
    Map<String, dynamic> remote,
  ) async {
    final details = await noteConflictDetails(operationId);
    if (details == null ||
        remote['patientId']?.toString() != details['patientId']?.toString() ||
        remote['tabKey']?.toString() != details['tabKey']?.toString() ||
        '${remote['pageNumber'] ?? 0}' != '${details['pageNumber'] ?? 0}' ||
        remote['scopeType']?.toString() != details['scopeType']?.toString() ||
        remote['scopeId']?.toString() != details['scopeId']?.toString()) {
      return false;
    }
    final drawing = await OfflineVault.instance.sealString(
      remote['drawingJson']?.toString() ?? '',
    );
    final hasText = remote.containsKey('textContent');
    final text = hasText
        ? await OfflineVault.instance.sealString(
            remote['textContent']?.toString() ?? '',
          )
        : null;
    final db = await _database.database;
    return db.transaction((txn) async {
      final operations = await txn.query(
        'sync_operations',
        columns: const ['entity_local_id'],
        where: 'id = ? AND entity_type = ? AND status = ?',
        whereArgs: [operationId, 'note_page', 'conflict'],
        limit: 1,
      );
      if (operations.length != 1) return false;
      final values = <String, Object?>{
        'drawing_json': drawing,
        if (hasText) 'text_content': text,
        'drawing_remote_path': remote['remotePath']?.toString() ?? '',
        'drawing_remote_url': remote['remoteUrl']?.toString() ?? '',
        'remote_revision': remote['revision']?.toString(),
        if (remote.containsKey('planPhase'))
          'plan_phase': remote['planPhase']?.toString(),
        'updated_at':
            remote['updatedAt']?.toString() ?? DateTime.now().toIso8601String(),
        'sync_state': SyncState.synced.name,
      };
      final changed = await txn.update(
        'note_pages',
        values,
        where: 'local_id = ?',
        whereArgs: [operations.single['entity_local_id']],
      );
      if (changed != 1) return false;
      final removed = await txn.delete(
        'sync_operations',
        where: 'id = ? AND status = ?',
        whereArgs: [operationId, 'conflict'],
      );
      return removed == 1;
    });
  }

  /// Réinitialise UNE op à `pending` (attempt_count=0, last_error=null).
  /// Renvoie le nombre de lignes modifiées (0 ou 1).
  Future<int> resetSingleOperationToPending(String operationId) async {
    final db = await _database.database;
    return db.update(
      'sync_operations',
      {
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.failed.name],
    );
  }

  String? _noteConflictRevision(Object? conflict) {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    String? search(Object? value) {
      if (value is Map) {
        for (final key in const ['revision', 'app_sync_revision']) {
          final candidate = value[key]?.toString();
          if (candidate != null && uuid.hasMatch(candidate)) return candidate;
        }
        for (final nested in value.values) {
          final found = search(nested);
          if (found != null) return found;
        }
      } else if (value is List) {
        for (final nested in value) {
          final found = search(nested);
          if (found != null) return found;
        }
      }
      return null;
    }

    return search(conflict);
  }

  /// Supprime UNE op de la file (utilisé par "Abandonner" sur une
  /// modif locale qu'on sait condamnée — payload obsolète, ressource
  /// distante effacée, etc.).
  Future<int> discardSingleOperation(String operationId) async {
    final db = await _database.database;
    return db.delete(
      'sync_operations',
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, SyncOperationStatus.failed.name],
    );
  }

  /// Supprime TOUTES les opérations en `failed` — permet à l'utilisateur de
  /// débloquer le bandeau rouge quand une modification ne pourra jamais
  /// aboutir (ex: ressource supprimée côté serveur).
  Future<int> discardFailedOperations() async {
    final db = await _database.database;
    return db.delete(
      'sync_operations',
      where: 'status = ?',
      whereArgs: [SyncOperationStatus.failed.name],
    );
  }

  /// Boot must retain conflicts, including older operations without a snapshot.
  /// Restore their entity indicators, but never requeue or acknowledge them.
  Future<int> restoreConflictedEntities() async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        columns: ['entity_type', 'entity_local_id'],
        where: 'status = ?',
        whereArgs: ['conflict'],
        distinct: true,
      );
      for (final row in rows) {
        await _updateEntitySyncState(
          db: txn,
          entityType: row['entity_type'] as String,
          entityLocalId: row['entity_local_id'] as String,
          syncState: SyncState.conflict,
        );
      }
      return rows.length;
    });
  }

  /// Met à jour le statut d'une `sync_operation`. Si [expectedStatus] est
  /// fourni, la transition n'a lieu QUE si le row est actuellement dans
  /// cet état — sinon `0` est renvoyé (no-op). Crucial pour le verrou
  /// par status="running" qui empêche un `markCompleted` de squasher
  /// un row qui a été remplacé par une nouvelle version pending pendant
  /// que le PATCH HTTP était en vol (cf. fix race « Bro → B »).
  ///
  /// Renvoie le nombre de lignes effectivement mises à jour (0 ou 1).
  Future<int> _updateOperation({
    required String operationId,
    required SyncOperationStatus status,
    required bool clearError,
    SyncOperationStatus? expectedStatus,
  }) async {
    final db = await _database.database;
    final values = <String, Object?>{
      'status': status.name,
      'updated_at': DateTime.now().toIso8601String(),
    };
    if (clearError) {
      values['last_error'] = null;
    }
    if (expectedStatus == null) {
      return db.update(
        'sync_operations',
        values,
        where: 'id = ?',
        whereArgs: [operationId],
      );
    }
    return db.update(
      'sync_operations',
      values,
      where: 'id = ? AND status = ?',
      whereArgs: [operationId, expectedStatus.name],
    );
  }

  Future<void> _updateEntitySyncState({
    required DatabaseExecutor db,
    required String entityType,
    required String entityLocalId,
    required SyncState syncState,
  }) async {
    // Housing mutations are keyed by dossier id, not by housings.local_id.
    if (entityType == 'housing') {
      await db.update(
        'housings',
        {'sync_state': syncState.name},
        where:
            'local_id IN (SELECT housing_local_id FROM dossiers WHERE local_id = ?)',
        whereArgs: [entityLocalId],
      );
      return;
    }
    // Bindings entity_type → table:colonne. Avant ce mapping complet,
    // les types `patient` / `housing` / `contexte_de_vie` /
    // `diagnostic_sanitaires` / `visit_recommendations` n'avaient PAS
    // de binding → leur sync_state restait à `pendingSync` indéfiniment
    // après un push réussi. Conséquence : `mergeRemoteDossierPayloads`
    // ne pouvait pas détecter qu'un patient avait une op en cours et
    // l'écrasait avec les données du serveur (qui pouvaient encore
    // refléter l'ancienne valeur en cas de eventual consistency NocoDB)
    // → flash visuel "le nom a disparu pendant quelques secondes".
    final binding = switch (entityType) {
      'dossier' => const _EntityBinding('dossiers', 'local_id'),
      'patient' => const _EntityBinding('patients', 'local_id'),
      'housing' => const _EntityBinding('housings', 'local_id'),
      'document' => const _EntityBinding('documents', 'local_id'),
      'note_page' => const _EntityBinding('note_pages', 'local_id'),
      'contexte_de_vie' => const _EntityBinding(
        'contexte_de_vie',
        'dossier_local_id',
      ),
      'diagnostic_sanitaires' => const _EntityBinding(
        'diagnostic_sanitaires',
        'dossier_local_id',
      ),
      'mesures_anthropometriques' => const _EntityBinding(
        'mesures_anthropometriques',
        'dossier_local_id',
      ),
      'observations_synthese' => const _EntityBinding(
        'observations_synthese',
        'dossier_local_id',
      ),
      'visit_recommendations' => const _EntityBinding(
        'visit_recommendations',
        'dossier_local_id',
      ),
      'wiki_item' => const _EntityBinding('wiki_items', 'id'),
      'retirement_fund' => const _EntityBinding('retirement_funds', 'id'),
      'access_member' => const _EntityBinding('access_members', 'email'),
      'profile_photo' => const _EntityBinding('app_users', 'local_id'),
      _ => null,
    };
    if (binding == null) return;

    await db.update(
      binding.table,
      {'sync_state': syncState.name},
      where: '${binding.idColumn} = ?',
      whereArgs: [entityLocalId],
    );
  }
}

const undefined = Object();

class _EntityBinding {
  final String table;
  final String idColumn;
  const _EntityBinding(this.table, this.idColumn);
}
