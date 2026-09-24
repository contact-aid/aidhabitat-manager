import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'local_database.dart';
import 'nocodb_api_client.dart';
import 'offline_vault.dart';
import 'sync_engine.dart';
import 'sync_mutation.dart';
import 'context_sync_protocol.dart';
import 'visit_recommendations_publication.dart';

class SyncConflictReview {
  SyncConflictReview._({
    required this.operationId,
    required this.entityType,
    required this.entityLocalId,
    required this.payloadJson,
    required this.remoteUpdatedAt,
    required this.localValues,
    required this.remoteValues,
    required this.remoteColumns,
    required this.localRowId,
    required this.table,
    required this.remoteExists,
    this.contextReferenceJson,
  });

  final String operationId;
  final String entityType;
  final String entityLocalId;
  final String payloadJson;
  // `null` : la fiche distante n'existe pas encore (saisie locale avant
  // le 1er sync) — rien a comparer, pas de garde de concurrence a poser
  // au push de la resolution (cf. `_expectedVersion` dans
  // nocodb_sync_service.dart, qui traite `null` comme « pas de version
  // connue », exactement comme pour une 1ere sauvegarde normale).
  final String? remoteUpdatedAt;
  final Map<String, dynamic> localValues;
  final Map<String, dynamic> remoteValues;
  final Map<String, dynamic> remoteColumns;
  final String localRowId;
  final String table;
  final bool remoteExists;
  final String? contextReferenceJson;
}

class DossierRepository {
  DossierRepository({LocalDatabase? database})
    : _database = database ?? LocalDatabase.instance;

  final LocalDatabase _database;

  String _uuid() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  Future<void> initialize() async {
    await _database.ensureSeeded();
  }

  Future<({String remoteDossierId, Set<String> entityTypes})>
  conflictReviewScope(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'dossiers',
      where: 'local_id = ?',
      whereArgs: [dossierId],
    );
    if (rows.length != 1) throw StateError('Dossier local introuvable.');
    final row = rows.single;
    final operations = await db.query(
      'sync_operations',
      columns: ['entity_type'],
      where:
          "status = 'conflict' AND ((entity_type = 'patient' AND entity_local_id = ?) OR (entity_type != 'patient' AND entity_local_id = ?))",
      whereArgs: [row['patient_local_id'], dossierId],
    );
    return (
      remoteDossierId: _remoteIdentity(row['remote_dossier_id'], dossierId),
      entityTypes: operations
          .map((row) => row['entity_type'] as String)
          .toSet(),
    );
  }

  static String _remoteIdentity(Object? remoteId, String localId) {
    final value = remoteId?.toString().trim();
    return value == null || value.isEmpty ? localId : value;
  }

  /// Build a review from the unfiltered server payload, not the reduced UI
  /// model. No local data changes during this read, including while offline.
  Future<List<SyncConflictReview>> reviewConflicts(
    String dossierId,
    Map<String, dynamic> remote,
  ) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final bundles = await txn.query(
        'dossiers',
        where: 'local_id = ?',
        whereArgs: [dossierId],
      );
      if (bundles.length != 1) throw StateError('Dossier local introuvable.');
      final bundle = bundles.single;
      if (remote['id'] !=
          _remoteIdentity(bundle['remote_dossier_id'], dossierId)) {
        throw StateError('Le dossier distant ne correspond pas.');
      }
      final patientId = bundle['patient_local_id'] as String;
      final patientRows = await txn.query(
        'patients',
        where: 'local_id = ?',
        whereArgs: [patientId],
      );
      final patient = (remote['patient'] as Map?)?.cast<String, dynamic>();
      if (patientRows.length != 1 ||
          patient == null ||
          patient['id'] !=
              _remoteIdentity(
                patientRows.single['remote_patient_id'],
                patientId,
              )) {
        throw StateError('Le beneficiaire distant ne correspond pas.');
      }
      final operations = await txn.query(
        'sync_operations',
        where:
            "status = 'conflict' AND ((entity_type = 'patient' AND entity_local_id = ?) OR (entity_type IN ('dossier', 'housing') AND entity_local_id = ?))",
        whereArgs: [patientId, dossierId],
        orderBy: 'created_at, id',
      );
      final reviews = <SyncConflictReview>[];
      for (final operation in operations) {
        final type = operation['entity_type'] as String;
        final payloadJson = await OfflineVault.instance.openString(
          operation['payload_json'] as String,
        );
        final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
        final updates = (payload['updates'] as Map).cast<String, dynamic>();
        final raw = type == 'patient'
            ? patient
            : type == 'housing'
            ? (remote['housing'] as Map?)?.cast<String, dynamic>()
            : remote;
        if (raw == null) throw StateError('Version distante incomplete.');
        final extractedVersion = _extractRemoteUpdatedAt(raw);
        final extractedVersionValid =
            extractedVersion != null &&
            DateTime.tryParse(extractedVersion) != null;
        // Un logement jamais créé côté serveur (saisie locale avant le 1er
        // sync) n'a pas d'`updatedAt` distant : ce n'est pas un conflit de
        // version, il n'y a simplement rien à comparer côté serveur (le
        // serveur renvoie alors explicitement `updatedAt: null`, jamais un
        // horodatage fabrique — cf. `mapHousing`). On l'affiche quand même
        // dans la revue (valeurs distantes vides) au lieu de bloquer toute
        // résolution avec « Version serveur absente » (cf. dossier
        // demo-technicien-20260917-annegaelle, 2026-09-22). Ce relâchement
        // ne s'applique qu'au logement : patient/dossier existent toujours
        // dès qu'un conflit est atteignable, donc une version manquante y
        // reste une vraie anomalie a rejeter (cf.
        // sync_conflict_resolution_test.dart « missing field or version is
        // not manufactured for a decision »).
        //
        // Le signal utilisé pour "logement absent" est directement la
        // validite de la version extraite, pas la presence de `raw['id']`
        // (essaye en premier, puis abandonne : certains payloads legitimes,
        // dont un fixture de test, omettent `id` tout en portant un vrai
        // `updatedAt` — s'appuyer sur `id` les aurait a tort traites comme
        // "absent" et fait perdre une version reelle).
        final remoteExists = type != 'housing' || extractedVersionValid;
        final version = remoteExists ? extractedVersion : null;
        if (remoteExists && !extractedVersionValid) {
          throw StateError('Version serveur absente : resolution suspendue.');
        }
        final now = DateTime.now().toIso8601String();
        final columns = type == 'patient'
            ? _buildPatientPayload(raw: raw, now: now)
            : type == 'housing'
            ? _buildHousingPayload(raw: raw, now: now)
            : _buildDossierPayload(raw: raw, now: now);
        final mapper = type == 'patient'
            ? _mapPatientFieldsToApi
            : type == 'housing'
            ? _mapHousingFieldsToApi
            : _mapDossierFieldsToApi;
        final remoteApi = mapper(columns);
        for (final key in updates.keys) {
          if (!remoteExists) continue;
          final rawKey = key == 'occupant1BirthDate' ? 'birthDate' : key;
          if (!raw.containsKey(rawKey) || !remoteApi.containsKey(key)) {
            throw StateError('Valeur distante absente pour $key.');
          }
        }
        // Restore only columns belonging to the explicitly reviewed patch.
        // In particular, unrelated dossier/context data must stay untouched.
        final selectedColumns = <String, dynamic>{};
        for (final column in columns.entries) {
          if ([
            'updated_at',
            'remote_updated_at',
            'sync_state',
          ].contains(column.key)) {
            continue;
          }
          if (mapper({
            column.key: column.value,
          }).keys.any(updates.containsKey)) {
            selectedColumns[column.key] = column.value;
          }
        }
        if (selectedColumns.isEmpty && remoteExists) {
          throw StateError('Aucun champ resoluble.');
        }
        reviews.add(
          SyncConflictReview._(
            operationId: operation['id'] as String,
            entityType: type,
            entityLocalId: operation['entity_local_id'] as String,
            payloadJson: payloadJson,
            remoteUpdatedAt: version,
            localValues: Map.unmodifiable(updates),
            remoteValues: Map.unmodifiable({
              for (final key in updates.keys)
                key: remoteExists ? remoteApi[key] : null,
            }),
            remoteColumns: Map.unmodifiable(selectedColumns),
            localRowId: type == 'patient'
                ? patientId
                : type == 'housing'
                ? bundle['housing_local_id'] as String
                : dossierId,
            table: type == 'patient'
                ? 'patients'
                : type == 'housing'
                ? 'housings'
                : 'dossiers',
            remoteExists: remoteExists,
          ),
        );
      }
      return reviews;
    });
  }

  static const _secondaryFields = <String, Map<String, String>>{
    'contexte_de_vie': {
      'medicalContext': 'medical_context_json',
      'autonomy': 'autonomy_json',
    },
    'mesures_anthropometriques': {
      'deboutHauteurCoude': 'debout_hauteur_coude',
      'assisHauteurAssise': 'assis_hauteur_assise',
      'assisProfondeurGenoux': 'assis_profondeur_genoux',
      'assisHauteurCoudes': 'assis_hauteur_coudes',
      'observations': 'observations',
    },
    'observations_synthese': {
      'observationEquipements': 'observation_equipements',
      'projetSouhaitUsage': 'projet_souhait_usage',
      'resumePreconisations': 'resume_preconisations',
    },
    'diagnostic_sanitaires': {
      'sdbInstances': 'sdb_instances_json',
      'wcInstances': 'wc_instances_json',
    },
  };

  Future<List<SyncConflictReview>> reviewSecondaryConflicts(
    String dossierId,
    Map<String, Map<String, dynamic>?> remoteByType,
  ) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final dossiers = await txn.query(
        'dossiers',
        where: 'local_id = ?',
        whereArgs: [dossierId],
      );
      if (dossiers.length != 1) throw StateError('Dossier local introuvable.');
      final remoteId = _remoteIdentity(
        dossiers.single['remote_dossier_id'],
        dossierId,
      );
      final reviews = <SyncConflictReview>[];
      for (final type in _secondaryFields.keys) {
        final operations = await txn.query(
          'sync_operations',
          where:
              "status = 'conflict' AND entity_type = ? AND entity_local_id = ?",
          whereArgs: [type, dossierId],
          orderBy: 'created_at, id',
        );
        if (operations.isEmpty) continue;
        if (!remoteByType.containsKey(type)) {
          throw StateError('Lecture distante de la fiche indisponible.');
        }
        final raw = remoteByType[type];
        final context = type == 'contexte_de_vie';
        final reference = context && raw?['serverReference'] != null
            ? ContextServerReference.fromJson(
                (raw!['serverReference'] as Map).cast<String, dynamic>(),
              )
            : null;
        final remoteExists = context ? reference != null : raw != null;
        final version = context
            ? reference?.updatedAt
            : raw == null
            ? null
            : _extractRemoteUpdatedAt(raw);
        if ((raw != null && raw['dossierId'] != remoteId) ||
            (context
                ? raw == null || !raw.containsKey('serverReference')
                : remoteExists &&
                      (version == null ||
                          DateTime.tryParse(version) == null))) {
          throw StateError('Version distante de la fiche indisponible.');
        }
        final rows = await txn.query(
          type,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
        if (rows.length != 1) throw StateError('Fiche locale introuvable.');
        final fields = _secondaryFields[type]!;
        for (final operation in operations) {
          final payloadJson = await OfflineVault.instance.openString(
            operation['payload_json'] as String,
          );
          final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
          final updates =
              (payload['updates'] as Map?)?.cast<String, dynamic>() ??
              (type == 'diagnostic_sanitaires'
                  ? {
                      for (final key in fields.keys)
                        if (payload.containsKey(key)) key: payload[key],
                    }
                  : <String, dynamic>{});
          if (updates.isEmpty) {
            throw StateError('Modification locale incomplete.');
          }
          if (type == 'diagnostic_sanitaires' &&
              !fields.keys.every(updates.containsKey)) {
            throw StateError('Diagnostic local incomplet.');
          }
          final values = <String, dynamic>{};
          final columns = <String, dynamic>{};
          for (final key in updates.keys) {
            if (!fields.containsKey(key) ||
                (remoteExists && !raw!.containsKey(key))) {
              throw StateError('Valeur distante absente pour $key.');
            }
            if (!remoteExists) {
              values[key] = null;
              continue;
            }
            final value = raw![key];
            if (context) {
              if (value is! Map) {
                throw StateError('Contexte distant incomplet.');
              }
              columns[fields[key]!] = jsonEncode(value);
            } else if (type == 'diagnostic_sanitaires') {
              if (value is! List || value.any((entry) => entry is! Map)) {
                throw StateError('Diagnostic distant incomplet.');
              }
              columns[fields[key]!] = jsonEncode(value);
            } else if (type == 'mesures_anthropometriques' &&
                key != 'observations') {
              if (value != null && (value is! num || !value.isFinite)) {
                throw StateError('Mesure distante invalide.');
              }
              columns[fields[key]!] = value;
            } else {
              if (value != null && value is! String) {
                throw StateError('Texte distant invalide.');
              }
              columns[fields[key]!] = value ?? '';
            }
            values[key] = value;
          }
          reviews.add(
            SyncConflictReview._(
              operationId: operation['id'] as String,
              entityType: type,
              entityLocalId: dossierId,
              payloadJson: payloadJson,
              remoteUpdatedAt: version,
              contextReferenceJson: context
                  ? jsonEncode(reference?.toJson())
                  : null,
              localValues: Map.unmodifiable(updates),
              remoteValues: Map.unmodifiable(values),
              remoteColumns: Map.unmodifiable(columns),
              localRowId: rows.single['local_id'] as String,
              table: type,
              remoteExists: remoteExists,
            ),
          );
        }
      }
      return reviews;
    });
  }

  Future<void> resolveReviewedConflict(
    SyncConflictReview review, {
    required bool keepLocal,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'sync_operations',
        where:
            'id = ? AND entity_type = ? AND entity_local_id = ? AND status = ?',
        whereArgs: [
          review.operationId,
          review.entityType,
          review.entityLocalId,
          'conflict',
        ],
      );
      if (rows.length != 1 ||
          await OfflineVault.instance.openString(
                rows.single['payload_json'] as String,
              ) !=
              review.payloadJson) {
        throw StateError('La saisie a change. Rechargez la comparaison.');
      }
      final others = await txn.query(
        'sync_operations',
        columns: ['id'],
        where:
            "entity_type = ? AND entity_local_id = ? AND id != ? AND status != 'completed'",
        whereArgs: [
          review.entityType,
          review.entityLocalId,
          review.operationId,
        ],
        limit: 1,
      );
      if (others.isNotEmpty) {
        throw StateError('Une autre modification attend sur cette fiche.');
      }
      if (!review.remoteExists && !keepLocal) {
        throw StateError('Aucune fiche serveur ne peut etre restauree.');
      }
      final now = DateTime.now().toIso8601String();
      await txn.insert('sync_conflict_history', {
        'operation_id': review.operationId,
        'entity_type': review.entityType,
        'entity_local_id': review.entityLocalId,
        'decision': keepLocal ? 'keep_local' : 'take_remote',
        'snapshot_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'mutation': jsonDecode(review.payloadJson),
            'remoteValues': review.remoteValues,
            'remoteUpdatedAt': review.remoteUpdatedAt,
          }),
        ),
        'created_at': now,
      });
      final payload = jsonDecode(review.payloadJson) as Map<String, dynamic>;
      payload.remove('conflict');
      payload.remove('localReference');
      payload.remove('retryMutation');
      payload['updates'] = review.localValues;
      if (review.entityType == 'diagnostic_sanitaires') {
        for (final key in _secondaryFields['diagnostic_sanitaires']!.keys) {
          payload[key] = review.localValues[key];
        }
      }
      payload['concurrency'] = {
        'version': 1,
        'writeId': newSyncWriteId(),
        'expectedUpdatedAt': review.remoteUpdatedAt,
        'baseValues': review.remoteExists ? review.remoteValues : {},
        if (!review.remoteExists) 'createIfAbsent': true,
        if (review.contextReferenceJson != null)
          'reference': jsonDecode(review.contextReferenceJson!),
      };
      await txn.update(
        'sync_operations',
        {
          'payload_json': await OfflineVault.instance.sealString(
            jsonEncode(payload),
          ),
          'status': keepLocal ? 'pending' : 'completed',
          'last_error': null,
          'attempt_count': 0,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [review.operationId],
      );
      final changed = await txn.update(
        review.table,
        {
          if (!keepLocal) ...review.remoteColumns,
          if (review.contextReferenceJson == null &&
              review.remoteUpdatedAt != null)
            'remote_updated_at': review.remoteUpdatedAt,
          if (review.contextReferenceJson != null) ...{
            'remote_reference_json': review.contextReferenceJson == 'null'
                ? null
                : review.contextReferenceJson,
            'remote_reference_known': 1,
          },
          'updated_at': now,
          'sync_state': keepLocal ? 'pendingSync' : 'synced',
        },
        where: 'local_id = ?',
        whereArgs: [review.localRowId],
      );
      if (changed != 1) throw StateError('Fiche locale introuvable.');
    });
    SyncEngine().notify();
  }

  /// Create a new beneficiary + housing + dossier locally. All three entities
  /// are inserted into SQLite with local IDs and a sync operation is enqueued
  /// for each so they are pushed to the server when connectivity is available.
  ///
  /// Returns the newly created [Dossier] immediately — no network required.
  ///
  /// Les champs admin du bloc bénéficiaire sont demandés dès la création
  /// (cf. `CreateBeneficiaryScreen`) pour que le dossier ait tout de
  /// suite assez de données pour le rapport PDF — d'où les params
  /// `natureAccompagnement` / `numberPeople` / `fiscalRevenue` / adresse.
  /// Tous restent optionnels au niveau du repo (avec defaults vides) pour
  /// ne pas casser d'éventuels appelants futurs.
  Future<Dossier> createDossierOffline({
    required String firstName,
    required String lastName,
    String ergoId = '',
    String natureAccompagnement = '',
    int numberPeople = 1,
    double? fiscalRevenue,
    String address = '',
    String city = '',
    String zipCode = '',
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final patientLocalId = _generateLocalId();
    final housingLocalId = _generateLocalId();
    final dossierLocalId = _generateLocalId();
    late Map<String, dynamic> patientBaseline;
    late Map<String, dynamic> dossierBaseline;

    final patient = Patient(
      id: patientLocalId,
      firstName: firstName,
      lastName: lastName,
      birthDate: '',
      phone: '',
      email: '',
      address: address,
      city: city,
      zipCode: zipCode,
      familySituation: '',
      incomeCategory: '',
      numberPeople: numberPeople,
      fiscalRevenue: fiscalRevenue,
      trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
    );

    final housing = Housing(
      type: HousingType.HOUSE,
      heating: HeatingMode.ELECTRIC,
      accessibilityNotes: '',
    );

    await db.transaction((txn) async {
      await txn.insert('patients', {
        'local_id': patientLocalId,
        'remote_patient_id': null,
        'first_name': firstName,
        'last_name': lastName,
        'birth_date': '',
        'phone': '',
        'email': '',
        'address': address,
        'city': city,
        'zip_code': zipCode,
        'family_situation': '',
        'occupation_status': '',
        'income_category': '',
        'number_people': numberPeople,
        'fiscal_revenue': fiscalRevenue,
        'trusted_person_json': jsonEncode({
          'name': '',
          'phone': '',
          'email': '',
        }),
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      await txn.insert('housings', {
        'local_id': housingLocalId,
        'remote_housing_id': null,
        'patient_local_id': patientLocalId,
        'type': HousingType.HOUSE.name,
        'year_value': null,
        'surface': null,
        'heating_mode': HeatingMode.ELECTRIC.name,
        'accessibility_notes': '',
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      await txn.insert('dossiers', {
        'local_id': dossierLocalId,
        'remote_dossier_id': null,
        'patient_local_id': patientLocalId,
        'housing_local_id': housingLocalId,
        'status': DossierStatus.TO_VISIT.name,
        'ergo_id': ergoId,
        'visit_date': null,
        'autonomy_notes': '',
        'nature_accompagnement': natureAccompagnement,
        'plans_json': jsonEncode(['PF1', 'PF2', 'PF3']),
        'created_at': now,
        'updated_at': now,
        'remote_updated_at': null,
        'sync_state': SyncState.localOnly.name,
      });

      // Enqueue a sync operation to create the full dossier on the server
      // when connectivity is available. Le serveur lit ces champs dans
      // POST /api/beneficiaires (cf. mapBeneficiaryUpdatesToFields +
      // bloc nature_accompagnement spécifique au dossier).
      await txn.insert('sync_operations', {
        'id': 'create_$dossierLocalId',
        'entity_type': 'dossier',
        'entity_local_id': dossierLocalId,
        'operation_type': 'create',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'dossierLocalId': dossierLocalId,
            'patientLocalId': patientLocalId,
            'housingLocalId': housingLocalId,
            'firstName': firstName,
            'lastName': lastName,
            'ergoId': ergoId,
            'natureAccompagnement': natureAccompagnement,
            'numberPeople': numberPeople,
            if (fiscalRevenue != null) 'fiscalRevenue': fiscalRevenue,
            'address': address,
            'city': city,
            'zipCode': zipCode,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
      patientBaseline = Map.of(
        (await txn.query(
          'patients',
          where: 'local_id = ?',
          whereArgs: [patientLocalId],
          limit: 1,
        )).single,
      );
      dossierBaseline = Map.of(
        (await txn.query(
          'dossiers',
          where: 'local_id = ?',
          whereArgs: [dossierLocalId],
          limit: 1,
        )).single,
      );
    });

    SyncEngine().notify();

    return Dossier(
      id: dossierLocalId,
      patientEditBaseline: Map.unmodifiable(patientBaseline),
      dossierEditBaseline: Map.unmodifiable(dossierBaseline),
      patient: patient,
      status: DossierStatus.TO_VISIT,
      ergoId: ergoId,
      housing: housing,
      autonomyNotes: '',
      natureAccompagnement: natureAccompagnement,
      plans: const {
        'PF1': FinancialPlan(id: 'PF1'),
        'PF2': FinancialPlan(id: 'PF2'),
        'PF3': FinancialPlan(id: 'PF3'),
      },
      createdAt: now,
      syncState: SyncState.localOnly,
    );
  }

  /// Update local patient fields for an existing dossier and enqueue a sync.
  Future<void> updatePatientLocal({
    required String patientLocalId,
    required Map<String, dynamic> updates,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    final dbUpdates = <String, dynamic>{'updated_at': now};
    if (updates.containsKey('firstName')) {
      dbUpdates['first_name'] = updates['firstName'];
    }
    if (updates.containsKey('lastName')) {
      dbUpdates['last_name'] = updates['lastName'];
    }
    if (updates.containsKey('phone')) {
      dbUpdates['phone'] = updates['phone'];
    }
    if (updates.containsKey('email')) {
      dbUpdates['email'] = updates['email'];
    }
    if (updates.containsKey('address')) {
      dbUpdates['address'] = updates['address'];
    }
    if (updates.containsKey('city')) {
      dbUpdates['city'] = updates['city'];
    }
    if (updates.containsKey('zipCode')) {
      dbUpdates['zip_code'] = updates['zipCode'];
    }
    if (updates.containsKey('birthDate')) {
      dbUpdates['birth_date'] = updates['birthDate'];
    }
    if (updates.containsKey('familySituation')) {
      dbUpdates['family_situation'] = updates['familySituation'];
    }
    if (updates.containsKey('incomeCategory')) {
      dbUpdates['income_category'] = updates['incomeCategory'];
    }

    // Only update sync_state if currently synced — don't overwrite localOnly
    final currentRows = await db.query(
      'patients',
      columns: ['sync_state'],
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
      limit: 1,
    );
    if (currentRows.isNotEmpty) {
      final current = currentRows.first['sync_state'] as String;
      if (current == SyncState.synced.name) {
        dbUpdates['sync_state'] = SyncState.pendingSync.name;
      }
    }

    await db.update(
      'patients',
      dbUpdates,
      where: 'local_id = ?',
      whereArgs: [patientLocalId],
    );

    // Enqueue sync operation (upsert by entity key to avoid duplicates).
    final opId = 'patient_update_$patientLocalId';
    await db.insert('sync_operations', {
      'id': opId,
      'entity_type': 'patient',
      'entity_local_id': patientLocalId,
      'operation_type': 'update',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({'patientLocalId': patientLocalId, 'updates': updates}),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    SyncEngine().notify();
  }

  /// Met à jour le flag « bénéficiaire préparé » en local, puis l'ajoute à
  /// la file de synchronisation du dossier. L'écriture SQLite reste
  /// immédiate hors ligne et NocoDB réconcilie ensuite les autres appareils.
  Future<void> setBeneficiaryPrepared({
    required String dossierLocalId,
    required bool prepared,
  }) async {
    await updateDossierFields(dossierLocalId, {
      'beneficiary_prepared': prepared ? 1 : 0,
    });
  }

  static String _generateLocalId() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return 'local_$hex';
  }

  /// Fetches a single dossier by its local id, returning null if missing.
  /// Used by screens that want to re-read fresh patient/housing data after
  /// a save that happened in a child widget (e.g. the visit report tabs).
  Future<Dossier?> fetchDossierById(String dossierLocalId) async {
    final all = await fetchAllDossiers();
    for (final d in all) {
      if (d.id == dossierLocalId) return d;
    }
    return null;
  }

  Future<List<Dossier>> fetchAllDossiers() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT
        d.local_id AS dossier_local_id,
        d.remote_dossier_id AS dossier_remote_id,
        d.status AS dossier_status,
        d.ergo_id AS dossier_ergo_id,
        d.visit_date AS dossier_visit_date,
        d.autonomy_notes AS dossier_autonomy_notes,
        d.created_at AS dossier_created_at,
        d.sync_state AS dossier_sync_state,
        d.compte_anah AS dossier_compte_anah,
        d.nature_accompagnement AS dossier_nature_accompagnement,
        d.envoi_rapport AS dossier_envoi_rapport,
        d.personnes_presentes_visite AS dossier_personnes_presentes,
        d.beneficiary_prepared AS dossier_beneficiary_prepared,
        p.sync_state AS patient_sync_state,
        h.sync_state AS housing_sync_state,
        EXISTS (
          SELECT 1 FROM sync_operations child_op
          WHERE child_op.entity_local_id = d.local_id
            AND child_op.status = 'conflict'
            AND child_op.entity_type IN (
              'contexte_de_vie', 'mesures_anthropometriques',
              'observations_synthese', 'diagnostic_sanitaires',
              'visit_recommendations'
            )
        ) AS child_conflict,
        p.local_id AS patient_local_id,
        p.remote_patient_id AS patient_remote_id,
        p.first_name AS patient_first_name,
        p.last_name AS patient_last_name,
        p.second_first_name AS patient_second_first_name,
        p.second_last_name AS patient_second_last_name,
        p.birth_date AS patient_birth_date,
        p.phone AS patient_phone,
        p.email AS patient_email,
        p.address AS patient_address,
        p.city AS patient_city,
        p.city_id AS patient_city_id,
        p.zip_code AS patient_zip_code,
        p.family_situation AS patient_family_situation,
        p.occupation_status AS patient_occupation_status,
        p.income_category AS patient_income_category,
        p.number_people AS patient_number_people,
        p.fiscal_revenue AS patient_fiscal_revenue,
        p.occupants_json AS patient_occupants_json,
        p.apa AS patient_apa,
        p.invalidity AS patient_invalidity,
        p.invalidity_txt AS patient_invalidity_txt,
        p.home_help AS patient_home_help,
        p.home_help_txt AS patient_home_help_txt,
        p.dependence_txt AS patient_dependence_txt,
        p.caisse_retraite_principale AS patient_caisse_retraite_principale,
        p.caisses_retraite_complementaires AS patient_caisses_retraite_complementaires,
        p.trusted_person_json AS patient_trusted_person_json,
        h.local_id AS housing_local_id,
        h.type AS housing_type,
        h.year_value AS housing_year_value,
        h.surface AS housing_surface,
        h.heating_mode AS housing_heating_mode,
        h.accessibility_notes AS housing_accessibility_notes,
        h.year_construction AS housing_year_construction,
        h.year_habitation AS housing_year_habitation,
        h.levels AS housing_levels,
        h.typology AS housing_typology,
        h.basement AS housing_basement,
        h.basement_desc AS housing_basement_desc,
        h.basement_rooms_json AS housing_basement_rooms,
        h.rdc AS housing_rdc,
        h.rdc_desc AS housing_rdc_desc,
        h.rdc_rooms_json AS housing_rdc_rooms,
        h.floor AS housing_floor,
        h.floor_desc AS housing_floor_desc,
        h.floor_rooms_json AS housing_floor_rooms,
        h.second_floor AS housing_second_floor,
        h.second_floor_desc AS housing_second_floor_desc,
        h.second_floor_rooms_json AS housing_second_floor_rooms,
        h.third_floor AS housing_third_floor,
        h.third_floor_desc AS housing_third_floor_desc,
        h.third_floor_rooms_json AS housing_third_floor_rooms,
        h.garage AS housing_garage,
        h.veranda AS housing_veranda,
        h.balcon AS housing_balcon,
        h.terrasse AS housing_terrasse,
        h.jardin AS housing_jardin,
        h.heating_details_json AS housing_heating_details,
        h.volets_roulants_manuels_localisation AS housing_volets_man_loc,
        h.volets_roulants_manuels_entier AS housing_volets_man_entier,
        h.volets_roulants_electriques_localisation AS housing_volets_elec_loc,
        h.volets_roulants_electriques_entier AS housing_volets_elec_entier,
        h.volets_persiennes_localisation AS housing_volets_pers_loc,
        h.volets_persiennes_entier AS housing_volets_pers_entier,
        h.porte_garage_id AS housing_porte_garage_id,
        h.portail_id AS housing_portail_id,
        h.motorisation_porte_garage AS housing_motorisation_porte_garage,
        h.motorisation_portail AS housing_motorisation_portail,
        h.easy_access AS housing_easy_access,
        h.comments AS housing_comments,
        h.access_observation AS housing_access_observation
      FROM dossiers d
      INNER JOIN patients p ON p.local_id = d.patient_local_id
      INNER JOIN housings h ON h.local_id = d.housing_local_id
      ORDER BY d.created_at DESC
    ''');

    return rows.map(_mapDossierRow).toList();
  }

  Future<List<SyncOperation>> fetchPendingOperations() async {
    final db = await _database.database;
    final rows = await db.query(
      'sync_operations',
      where: 'status != ?',
      whereArgs: [SyncOperationStatus.completed.name],
      orderBy: 'created_at ASC',
    );

    final out = <SyncOperation>[];
    for (final row in rows) {
      out.add(
        SyncOperation(
          id: row['id'] as String,
          entityType: row['entity_type'] as String,
          entityLocalId: row['entity_local_id'] as String,
          operationType: row['operation_type'] as String,
          payloadJson: await OfflineVault.instance.openString(
            row['payload_json'] as String,
          ),
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

  Future<void> mergeRemoteDossiers(List<Dossier> remoteDossiers) async {
    if (remoteDossiers.isEmpty) return;
    final db = await _database.database;

    await db.transaction((txn) async {
      for (final dossier in remoteDossiers) {
        final existingRows = await txn.query(
          'dossiers',
          columns: ['sync_state'],
          where: 'local_id = ?',
          whereArgs: [dossier.id],
          limit: 1,
        );

        final existingSyncState = existingRows.isEmpty
            ? SyncState.synced
            : SyncState.values.byName(
                existingRows.first['sync_state'] as String,
              );

        // Chemin legacy : comme le merge principal, il garde une saisie
        // locale non acquittée quelle que soit la date du serveur.
        if (existingRows.isNotEmpty && existingSyncState != SyncState.synced) {
          continue;
        }

        final now = DateTime.now().toIso8601String();
        await txn.insert('patients', {
          'local_id': dossier.patient.id,
          'remote_patient_id': dossier.patient.id,
          'first_name': dossier.patient.firstName,
          'last_name': dossier.patient.lastName,
          'birth_date': dossier.patient.birthDate,
          'phone': dossier.patient.phone,
          'email': dossier.patient.email,
          'address': dossier.patient.address,
          'city': dossier.patient.city,
          'zip_code': dossier.patient.zipCode,
          'family_situation': dossier.patient.familySituation,
          'occupation_status': dossier.patient.occupationStatus,
          'income_category': dossier.patient.incomeCategory,
          // Preserve numberPeople across the pull → merge → UI round-trip.
          // Without this, ConflictAlgorithm.replace would reset the column
          // to NULL on every remote refresh, making the dropdown fall back
          // to "1 occupant" after a restart even when the server still has
          // the correct value.
          'number_people': dossier.patient.numberPeople,
          'trusted_person_json': jsonEncode({
            'name': dossier.patient.trustedPerson.name,
            'phone': dossier.patient.trustedPerson.phone,
            'email': dossier.patient.trustedPerson.email,
          }),
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final housingLocalId = 'housing_${dossier.id}';
        await txn.insert('housings', {
          'local_id': housingLocalId,
          'remote_housing_id': housingLocalId,
          'patient_local_id': dossier.patient.id,
          'type': dossier.housing.type.name,
          'year_value': dossier.housing.year,
          'surface': dossier.housing.surface,
          'heating_mode': dossier.housing.heating.name,
          'accessibility_notes': dossier.housing.accessibilityNotes,
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        await txn.insert('dossiers', {
          'local_id': dossier.id,
          'remote_dossier_id': dossier.id,
          'patient_local_id': dossier.patient.id,
          'housing_local_id': housingLocalId,
          'status': dossier.status.name,
          'ergo_id': dossier.ergoId,
          'visit_date': dossier.visitDate,
          'autonomy_notes': dossier.autonomyNotes,
          'beneficiary_prepared': dossier.beneficiaryPrepared ? 1 : 0,
          'plans_json': jsonEncode(dossier.plans.keys.toList()),
          'created_at': dossier.createdAt,
          'updated_at': now,
          'remote_updated_at': now,
          'sync_state': SyncState.synced.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  /// Merge raw dossier payloads (as returned by `/api/dossiers`) into the
  /// local SQLite store. Unlike [mergeRemoteDossiers] this path has access
  /// to the full JSON sent by the server and can therefore persist ALL
  /// extended columns (number_people, fiscal_revenue, apa, invalidity,
  /// occupants_json, heating_details_json, per-floor rooms, cheminement_*,
  /// medical_context_json, autonomy_json, etc.).
  ///
  /// UPDATE is used when the row already exists in the `synced` state, so
  /// columns the server doesn't return (e.g. local-only flags) are NOT
  /// wiped. INSERT-or-replace is used only for rows that don't exist yet.
  /// Bundles with outstanding mutations are preserved regardless of the
  /// incoming timestamp. A newer snapshot may repair orphaned sync states
  /// only when there is no queued mutation to protect.
  Future<void> mergeRemoteDossierPayloads(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return;
    final db = await _database.database;

    // Sets canoniques d'IDs remote — utilisés à la fin de la transaction
    // pour réconcilier les suppressions côté NocoDB (toute ligne
    // `synced` localement qui n'apparaît plus dans la liste remote a
    // été supprimée sur le serveur → on la purge en local).
    final remoteDossierIds = <String>{};
    final remotePatientIds = <String>{};
    final remoteHousingIds = <String>{};

    await db.transaction((txn) async {
      // A newer remote snapshot is not an acknowledgement of a local write.
      // Protect the whole bundle when an operation is outstanding OR a local
      // row still says unsynced, including if its operation is missing.
      // Only identifiers are loaded; queued PDFs/JSON payloads stay on disk.
      final protectedBundles = await txn.rawQuery('''
        SELECT d.local_id, d.patient_local_id, d.housing_local_id
        FROM dossiers AS d
        LEFT JOIN patients AS p ON p.local_id = d.patient_local_id
        LEFT JOIN housings AS h ON h.local_id = d.housing_local_id
        WHERE d.sync_state != 'synced'
          OR (p.sync_state IS NOT NULL AND p.sync_state != 'synced')
          OR (h.sync_state IS NOT NULL AND h.sync_state != 'synced')
          OR EXISTS (
          SELECT 1 FROM sync_operations AS op
          WHERE op.status IN ('pending', 'running', 'failed', 'conflict')
            AND (
              (op.entity_type IN ('dossier', 'contexte_de_vie')
                AND op.entity_local_id = d.local_id)
              OR (op.entity_type = 'patient'
                AND op.entity_local_id = d.patient_local_id)
              OR (op.entity_type = 'housing'
                AND op.entity_local_id IN (d.local_id, d.housing_local_id))
            )
        )
      ''');
      final protectedDossierIds = <String>{};
      final protectedPatientIds = <String>{};
      for (final bundle in protectedBundles) {
        final dossierId = bundle['local_id'] as String;
        final patientId = bundle['patient_local_id'] as String;
        final housingId = bundle['housing_local_id'] as String;
        protectedDossierIds.add(dossierId);
        protectedPatientIds.add(patientId);
        // Deletion reconciliation must preserve the same local bundle if
        // it is missing from this response, not just skip incoming updates.
        remoteDossierIds.add(dossierId);
        remotePatientIds.add(patientId);
        remoteHousingIds.add(housingId);
      }

      for (final raw in payloads) {
        final dossierId = raw['id']?.toString() ?? '';
        if (dossierId.isEmpty) continue;
        remoteDossierIds.add(dossierId);
        final pJson = (raw['patient'] as Map?)?.cast<String, dynamic>();
        final pid = pJson?['id']?.toString() ?? dossierId;
        remotePatientIds.add(pid);
        remoteHousingIds.add('housing_$dossierId');

        if (protectedDossierIds.contains(dossierId) ||
            protectedPatientIds.contains(pid)) {
          continue;
        }

        final existingDossier = await txn.query(
          'dossiers',
          columns: [
            'sync_state',
            'patient_local_id',
            'housing_local_id',
            'workspace_updated_at',
          ],
          where: 'local_id = ?',
          whereArgs: [dossierId],
          limit: 1,
        );

        final existingSyncState = existingDossier.isEmpty
            ? SyncState.synced
            : SyncState.values.byName(
                existingDossier.first['sync_state'] as String,
              );

        if (existingDossier.isNotEmpty &&
            existingSyncState != SyncState.synced) {
          // Un horodatage distant ne prouve pas que la saisie locale a été
          // publiée. La conserver même si la file d'opérations est absente.
          continue;
        }

        // Garde de second niveau : on regarde aussi le `patients.sync_state`
        // ET le `housings.sync_state` du dossier. Avant cette garde, un
        // pull NocoDB pouvait écraser un patient ou un housing en cours
        // de push, parce que `dossiers.sync_state` était à `synced` mais
        // `patients.sync_state` était à `pendingSync`. Symptôme côté UI :
        // « le nom modifié disparaît pendant quelques secondes » — le
        // serveur renvoyait l'ancien nom (eventual consistency) et le
        // merge l'écrivait par-dessus le nouveau nom local.
        //
        if (existingDossier.isNotEmpty) {
          final patientLocalIdExisting =
              existingDossier.first['patient_local_id'] as String?;
          final housingLocalIdExisting =
              existingDossier.first['housing_local_id'] as String?;
          if (patientLocalIdExisting != null &&
              patientLocalIdExisting.isNotEmpty) {
            final pRows = await txn.query(
              'patients',
              columns: ['sync_state'],
              where: 'local_id = ?',
              whereArgs: [patientLocalIdExisting],
              limit: 1,
            );
            if (pRows.isNotEmpty) {
              final pState = pRows.first['sync_state'] as String?;
              if (pState != null && pState != SyncState.synced.name) {
                continue;
              }
            }
          }
          if (housingLocalIdExisting != null &&
              housingLocalIdExisting.isNotEmpty) {
            final hRows = await txn.query(
              'housings',
              columns: ['sync_state'],
              where: 'local_id = ?',
              whereArgs: [housingLocalIdExisting],
              limit: 1,
            );
            if (hRows.isNotEmpty) {
              final hState = hRows.first['sync_state'] as String?;
              if (hState != null && hState != SyncState.synced.name) {
                continue;
              }
            }
          }

          // Garde de troisième niveau : fenêtre anti-flicker (30 s)
          // après une sync_op récemment `completed`. Le sync_state
          // local repasse à `synced` dès que markCompleted s'exécute,
          // mais NocoDB peut encore renvoyer l'ancienne valeur côté
          // read replica pendant la durée de propagation. Si un
          // refresh tombe dans ce trou, le merge écrase la valeur
          // locale fraîche par la valeur stale du serveur — l'ergo
          // voit le nom revenir à une version antérieure (« Yanis
          // Foyer » → « Yanis test » signalé le 2026-04-28).
          //
          // 2026-04-30 : fenêtre passée de 10 s à 30 s. Symptôme
          // reporté : « pendant plusieurs secondes le patient n'avait
          // plus de nom de famille avant que celui que j'ai mis
          // revienne ». 10 s ne suffisaient pas à couvrir la latence
          // d'eventual consistency NocoDB sur certains réseaux.
          //
          // On regarde aussi les ops non-terminées (pending/running/
          // failed) pour cette entité : si elles existent c'est qu'il
          // y a du travail en cours, surtout pas d'écraser le local.
          final cutoff = DateTime.now()
              .subtract(const Duration(seconds: 30))
              .toIso8601String();
          final recentPatientOps = patientLocalIdExisting == null
              ? const <Map<String, Object?>>[]
              : await txn.rawQuery(
                  '''
                  SELECT 1 FROM sync_operations
                  WHERE entity_type = 'patient'
                    AND entity_local_id = ?
                    AND (
                      status IN ('pending', 'running', 'failed')
                      OR (status = 'completed' AND updated_at > ?)
                    )
                  LIMIT 1
                  ''',
                  [patientLocalIdExisting, cutoff],
                );
          if (recentPatientOps.isNotEmpty) {
            continue;
          }
          final recentHousingOps = housingLocalIdExisting == null
              ? const <Map<String, Object?>>[]
              : await txn.rawQuery(
                  '''
                  SELECT 1 FROM sync_operations
                  WHERE entity_type = 'housing'
                    AND entity_local_id = ?
                    AND (
                      status IN ('pending', 'running', 'failed')
                      OR (status = 'completed' AND updated_at > ?)
                    )
                  LIMIT 1
                  ''',
                  [housingLocalIdExisting, cutoff],
                );
          if (recentHousingOps.isNotEmpty) {
            continue;
          }

          // Après la fenêtre anti-flicker, un snapshot de même version doit
          // pouvoir réparer un cache local déjà marqué `synced`. On ne refuse
          // donc plus que les snapshots réellement plus anciens. L'ancienne
          // comparaison `<=` figeait indéfiniment certains caches Web : le
          // serveur renvoyait la bonne ligne au même timestamp, mais le merge
          // n'était jamais rejoué.
          final remoteUpdatedAtIncoming = _extractWorkspaceUpdatedAt(raw);
          if (remoteUpdatedAtIncoming != null && existingDossier.isNotEmpty) {
            final localWorkspaceUpdatedAt =
                existingDossier.first['workspace_updated_at'] as String?;
            if (localWorkspaceUpdatedAt != null &&
                localWorkspaceUpdatedAt.isNotEmpty &&
                _isRemoteTimestampOlder(
                  remoteUpdatedAtIncoming,
                  localWorkspaceUpdatedAt,
                )) {
              continue;
            }
          }
        }

        final now = DateTime.now().toIso8601String();
        final patientJson =
            (raw['patient'] as Map?)?.cast<String, dynamic>() ?? const {};
        final housingJson =
            (raw['housing'] as Map?)?.cast<String, dynamic>() ?? const {};

        final patientLocalId = patientJson['id']?.toString() ?? dossierId;
        final housingLocalId = existingDossier.isEmpty
            ? 'housing_$dossierId'
            : existingDossier.first['housing_local_id'] as String;

        // ------------------------------------------------------------------
        // Patient upsert
        // ------------------------------------------------------------------
        final patientData = _buildPatientPayload(raw: patientJson, now: now);
        patientData['local_id'] = patientLocalId;
        patientData['remote_patient_id'] = patientLocalId;
        await _upsertByLocalId(
          txn: txn,
          table: 'patients',
          localId: patientLocalId,
          data: patientData,
        );

        // ------------------------------------------------------------------
        // Housing upsert
        // ------------------------------------------------------------------
        final housingData = _buildHousingPayload(raw: housingJson, now: now);
        housingData['local_id'] = housingLocalId;
        housingData['remote_housing_id'] = housingLocalId;
        housingData['patient_local_id'] = patientLocalId;
        await _upsertByLocalId(
          txn: txn,
          table: 'housings',
          localId: housingLocalId,
          data: housingData,
        );

        // ------------------------------------------------------------------
        // Dossier upsert
        // ------------------------------------------------------------------
        final dossierData = _buildDossierPayload(raw: raw, now: now);
        dossierData['local_id'] = dossierId;
        dossierData['remote_dossier_id'] = dossierId;
        dossierData['patient_local_id'] = patientLocalId;
        dossierData['housing_local_id'] = housingLocalId;
        dossierData['plans_json'] = jsonEncode(const ['PF1', 'PF2', 'PF3']);
        dossierData['created_at'] = raw['createdAt']?.toString() ?? now;
        dossierData['workspace_updated_at'] =
            _extractWorkspaceUpdatedAt(raw) ??
            _extractRemoteUpdatedAt(raw) ??
            now;
        await _upsertByLocalId(
          txn: txn,
          table: 'dossiers',
          localId: dossierId,
          data: dossierData,
        );

        // Contexte de vie possède sa propre table SQLite. Le payload distant
        // était auparavant stocké uniquement dans `dossiers`, alors que
        // ContextTab lit `contexte_de_vie` : les données multi-occupants
        // restaient donc figées ou vides sur un autre appareil.
        await _mergeRemoteContexteDeVie(
          txn: txn,
          raw: raw,
          dossierId: dossierId,
          patientLocalId: patientLocalId,
          now: now,
        );
      }

      // ----------------------------------------------------------------
      // Réconciliation des suppressions remote (chantier sync #1).
      //
      // Pour chaque table dont la liste remote vient d'être pullée
      // intégralement, on supprime toute ligne localement `synced`
      // dont l'identifiant n'apparaît plus dans la liste remote.
      // Les drafts locaux (sync_state != synced) sont préservés.
      //
      // Garde-fou : le payload remote est non-vide (vérifié au-dessus
      // dans `refreshWorkspaceFromRemote`) — donc une réponse API
      // vide ne déclenche jamais de purge de masse.
      // ----------------------------------------------------------------
      await _reconcileDeletions(
        txn: txn,
        table: 'dossiers',
        idColumn: 'local_id',
        remoteIds: remoteDossierIds,
      );
      await _reconcileDeletions(
        txn: txn,
        table: 'housings',
        idColumn: 'local_id',
        remoteIds: remoteHousingIds,
      );
      await _reconcileDeletions(
        txn: txn,
        table: 'patients',
        idColumn: 'local_id',
        remoteIds: remotePatientIds,
      );
      // Cascade applicative : nettoyage des rows liées aux dossiers
      // disparus (FK SQLite non garantie selon le schéma). On scope à
      // ce qui devient orphelin (parent_local_id absent du remote).
      await _purgeOrphansByParent(
        txn: txn,
        table: 'visit_recommendations',
        parentColumn: 'dossier_local_id',
        validParentIds: remoteDossierIds,
      );
      await _purgeOrphansByParent(
        txn: txn,
        table: 'documents',
        parentColumn: 'patient_local_id',
        validParentIds: remotePatientIds,
      );
    });
  }

  bool _isRemoteTimestampOlder(String remoteValue, String localValue) {
    final remote = DateTime.tryParse(remoteValue);
    final local = DateTime.tryParse(localValue);
    if (remote == null || local == null) {
      return remoteValue.compareTo(localValue) < 0;
    }
    return remote.isBefore(local);
  }

  Future<void> _mergeRemoteContexteDeVie({
    required Transaction txn,
    required Map<String, dynamic> raw,
    required String dossierId,
    required String patientLocalId,
    required String now,
  }) async {
    final hasMedical = raw['medicalContext'] is Map;
    final hasAutonomy = raw['autonomy'] is Map;
    if (!hasMedical && !hasAutonomy) return;

    final existing = await txn.query(
      'contexte_de_vie',
      columns: const ['local_id', 'sync_state'],
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      final syncState = existing.first['sync_state'] as String?;
      if (syncState != null && syncState != SyncState.synced.name) {
        return;
      }

      // Même après markCompleted, NocoDB peut brièvement relire l'ancienne
      // valeur. Cette fenêtre protège la copie locale fraîche, comme pour les
      // patients et logements dans le merge workspace principal.
      final cutoff = DateTime.now()
          .subtract(const Duration(seconds: 30))
          .toIso8601String();
      final activeOrRecentOperations = await txn.rawQuery(
        '''
        SELECT 1 FROM sync_operations
        WHERE entity_type = 'contexte_de_vie'
          AND entity_local_id = ?
          AND (
            status IN ('pending', 'running', 'failed', 'conflict')
            OR (status = 'completed' AND updated_at > ?)
          )
        LIMIT 1
        ''',
        [dossierId, cutoff],
      );
      if (activeOrRecentOperations.isNotEmpty) return;
    }

    final data = <String, dynamic>{
      'dossier_local_id': dossierId,
      'patient_local_id': patientLocalId,
      if (raw.containsKey('contextServerReference')) ...{
        'remote_reference_known': 1,
        'remote_reference_json': raw['contextServerReference'] == null
            ? null
            : jsonEncode(
                ContextServerReference.fromJson(
                  (raw['contextServerReference'] as Map)
                      .cast<String, dynamic>(),
                ).toJson(),
              ),
      },
      'updated_at': now,
      'sync_state': SyncState.synced.name,
    };
    if (hasMedical) {
      data['medical_context_json'] = jsonEncode(raw['medicalContext']);
    }
    if (hasAutonomy) {
      data['autonomy_json'] = jsonEncode(raw['autonomy']);
    }

    if (existing.isEmpty) {
      data['local_id'] = 'ctx_remote_$dossierId';
      await txn.insert('contexte_de_vie', data);
      return;
    }

    await txn.update(
      'contexte_de_vie',
      data,
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
    );
  }

  /// Supprime de [table] toutes les lignes en état `synced` dont
  /// l'identifiant ([idColumn]) n'apparaît plus dans [remoteIds].
  /// Les lignes en `pendingSync` ou `localOnly` (drafts) sont
  /// préservées : elles seront pushées au prochain cycle, et c'est le
  /// serveur qui décidera (création nouvelle, ou rejet 4xx → conflit).
  ///
  /// Si [remoteIds] est vide, on ne supprime rien (le caller doit
  /// avoir déjà filtré ce cas — éviter une purge totale en cas
  /// d'erreur silencieuse côté API).
  Future<int> _reconcileDeletions({
    required Transaction txn,
    required String table,
    required String idColumn,
    required Set<String> remoteIds,
  }) async {
    if (remoteIds.isEmpty) return 0;
    final placeholders = List.filled(remoteIds.length, '?').join(',');
    final args = <Object?>[SyncState.synced.name, ...remoteIds];
    final deleted = await txn.delete(
      table,
      where: 'sync_state = ? AND $idColumn NOT IN ($placeholders)',
      whereArgs: args,
    );
    if (deleted > 0) {
      // ignore: avoid_print
      print(
        '[reconcile] $table : $deleted ligne(s) purgée(s) (suppression remote)',
      );
    }
    return deleted;
  }

  /// Supprime les lignes orphelines : celles dont la colonne
  /// [parentColumn] référence un parent qui n'est plus dans
  /// [validParentIds]. Toujours scopé aux rows `synced` pour ne pas
  /// jeter un draft local en attente de push.
  Future<int> _purgeOrphansByParent({
    required Transaction txn,
    required String table,
    required String parentColumn,
    required Set<String> validParentIds,
  }) async {
    if (validParentIds.isEmpty) return 0;
    final placeholders = List.filled(validParentIds.length, '?').join(',');
    final args = <Object?>[SyncState.synced.name, ...validParentIds];
    final deleted = await txn.delete(
      table,
      where: 'sync_state = ? AND $parentColumn NOT IN ($placeholders)',
      whereArgs: args,
    );
    if (deleted > 0) {
      // ignore: avoid_print
      print(
        '[reconcile] $table : $deleted orphelin(s) purgé(s) (parent disparu)',
      );
    }
    return deleted;
  }

  /// Insert or UPDATE a row identified by `local_id`. If a row exists, the
  /// provided [data] is merged via UPDATE so columns not included in [data]
  /// keep their current values. Otherwise a fresh INSERT is performed.
  /// Colonnes des `patients` dépendant d'une table de référence côté
  /// NocoDB (`situation_proprietaire`, `statut_occupation`,
  /// `dependances_particulieres`, `caisses_retraite`, `caisses_retraite_comp`).
  /// Le PATCH serveur essaie de mapper l'étiquette saisie à un id de
  /// la table de réf via `findByLabel`. Si le matching échoue (label
  /// légèrement différent de la valeur stockée dans NocoDB), le serveur
  /// écrit `null` dans la colonne d'id → au prochain pull workspace le
  /// merge écrase localement notre saisie avec une valeur vide → la
  /// case "Propriétaire / Locataire / Usufruitier" se DÉSÉLECTIONNE
  /// toute seule quand l'utilisateur quitte puis revient sur le relevé.
  ///
  /// Garde-fou local : pendant le merge remote, si la nouvelle valeur
  /// est vide MAIS qu'on a déjà une valeur non-vide en SQLite, on
  /// préserve la valeur locale. Cas limite (user clearcase volontaire) :
  /// `_loadFromDossier` lit juste après une saisie locale, donc la
  /// valeur effacée sera bien re-poussée par la prochaine sync; le
  /// merge ne reverra "vide vs non-vide" que si le serveur a perdu la
  /// donnée — auquel cas on préfère garder le local.
  static const _patientFieldsPreserveOnEmpty = <String>{
    'family_situation',
    'occupation_status',
    'dependence_txt',
    'caisse_retraite_principale',
    'caisses_retraite_complementaires',
  };

  Future<void> _upsertByLocalId({
    required Transaction txn,
    required String table,
    required String localId,
    required Map<String, dynamic> data,
  }) async {
    // On ne peut plus se contenter de columns: ['local_id'] : pour la
    // garde "preserve on empty", on a besoin des valeurs courantes des
    // colonnes protégées.
    final protectedColumns = (table == 'patients')
        ? _patientFieldsPreserveOnEmpty.toList(growable: false)
        : const <String>[];
    final selectColumns = ['local_id', ...protectedColumns];

    final existing = await txn.query(
      table,
      columns: selectColumns,
      where: 'local_id = ?',
      whereArgs: [localId],
      limit: 1,
    );

    if (existing.isEmpty) {
      await txn.insert(
        table,
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return;
    }

    final updateFields = Map<String, dynamic>.from(data)..remove('local_id');

    // Garde-fou : pour chaque colonne référence-dépendante, si la
    // valeur entrante est vide ET qu'on en avait une non-vide en
    // local, on retombe sur la valeur locale.
    final existingRow = existing.first;
    for (final col in protectedColumns) {
      final incoming = updateFields[col];
      final isIncomingEmpty =
          incoming == null || (incoming is String && incoming.trim().isEmpty);
      if (!isIncomingEmpty) continue;
      final localValue = existingRow[col];
      final isLocalEmpty =
          localValue == null ||
          (localValue is String && localValue.trim().isEmpty);
      if (isLocalEmpty) continue;
      // Local a une valeur, remote n'en a pas → on garde la locale.
      updateFields[col] = localValue;
    }

    await txn.update(
      table,
      updateFields,
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  /// Maps a server-returned patient JSON to a SQLite row map covering the
  /// patients table's persisted columns. Values missing from [raw] fall
  /// back to safe defaults.
  Map<String, dynamic> _buildPatientPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    final trusted =
        (raw['trustedPerson'] as Map?)?.cast<String, dynamic>() ?? const {};
    return {
      'first_name': raw['firstName']?.toString() ?? '',
      'last_name': raw['lastName']?.toString() ?? '',
      'second_first_name': raw['secondFirstName']?.toString() ?? '',
      'second_last_name': raw['secondLastName']?.toString() ?? '',
      'birth_date': raw['birthDate']?.toString() ?? '',
      'phone': raw['phone']?.toString() ?? '',
      'email': raw['email']?.toString() ?? '',
      'address': raw['address']?.toString() ?? '',
      'city': raw['city']?.toString() ?? '',
      'city_id': raw['cityId']?.toString() ?? '',
      'zip_code': raw['zipCode']?.toString() ?? '',
      'family_situation': raw['familySituation']?.toString() ?? '',
      'occupation_status': raw['occupationStatus']?.toString() ?? '',
      'income_category': raw['incomeCategory']?.toString() ?? '',
      'number_people': _asInt(raw['numberPeople']),
      'fiscal_revenue': _asDouble(raw['fiscalRevenue']),
      'occupants_json': raw['occupants'] is List
          ? jsonEncode(raw['occupants'])
          : null,
      'apa': _asBoolInt(raw['apa']),
      'invalidity': _asBoolInt(raw['invalidity']),
      'invalidity_txt': raw['invalidityTxt']?.toString() ?? '',
      'home_help': _asBoolInt(raw['homeHelp']),
      'home_help_txt': raw['homeHelpTxt']?.toString() ?? '',
      'dependence_txt': raw['dependenceTxt']?.toString() ?? '',
      'caisse_retraite_principale':
          raw['caisseRetraitePrincipale']?.toString() ?? '',
      'caisses_retraite_complementaires':
          raw['caissesRetraiteComplementaires']?.toString() ?? '',
      'trusted_person_json': jsonEncode({
        'name': trusted['name']?.toString() ?? '',
        'phone': trusted['phone']?.toString() ?? '',
        'email': trusted['email']?.toString() ?? '',
      }),
      'updated_at': now,
      // Voir _buildDossierPayload : on stocke l'updatedAt serveur, pas
      // l'horodatage local du merge.
      'remote_updated_at': _extractRemoteUpdatedAt(raw),
      'sync_state': SyncState.synced.name,
    };
  }

  /// Maps a server-returned housing JSON to a SQLite row map covering every
  /// column persisted in the `housings` table, including the ones that are
  /// otherwise orphaned (no matching Dart model field): cheminement_*,
  /// heating_details_json, *_rooms_json, volets_*, etc.
  Map<String, dynamic> _buildHousingPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    // React/server heating shape: { electric, gas, oil, heatPump, collective,
    // wood, pellet, other }. Normalize to our Flutter label keys for storage
    // (matching what accessibility_tab writes locally).
    Map<String, dynamic> heatingDetailsJson = const {};
    final heating = raw['heatingDetails'];
    if (heating is Map) {
      heatingDetailsJson = {
        'Électrique': heating['electric'] == true,
        'Gaz': heating['gas'] == true,
        'Fioul': heating['oil'] == true,
        'Pompe à chaleur': heating['heatPump'] == true,
        'Bois': heating['wood'] == true,
        'Granulés': heating['pellet'] == true,
        'Collectif': heating['collective'] == true,
        'Autre': heating['other'] == true,
      };
    }

    // Primary heating mode (enum — guessed from the first true detail).
    final heatingMode = heatingDetailsJson['Électrique'] == true
        ? HeatingMode.ELECTRIC.name
        : heatingDetailsJson['Gaz'] == true
        ? HeatingMode.GAS.name
        : heatingDetailsJson['Bois'] == true ||
              heatingDetailsJson['Granulés'] == true
        ? HeatingMode.WOOD.name
        : heatingDetailsJson['Fioul'] == true
        ? HeatingMode.OIL.name
        : HeatingMode.OTHER.name;

    return {
      'type': _asHousingTypeName(raw['typology']),
      'year_value': _asInt(raw['yearConstruction']),
      'surface': _asDouble(raw['surface']),
      'heating_mode': heatingMode,
      'accessibility_notes':
          raw['accessibilityNotes']?.toString() ??
          raw['accessObservation']?.toString() ??
          '',
      'year_construction': raw['yearConstruction']?.toString() ?? '',
      'year_habitation': raw['yearHabitation']?.toString() ?? '',
      'levels': _asInt(raw['levels']),
      // Avant 2026-04-30 : défaut 'Maison' → la pill « Maison »
      // apparaissait pré-sélectionnée à l'ouverture du relevé même quand
      // l'ergo n'avait jamais cliqué dessus, et le validateur de pré-
      // génération ne pouvait pas signaler le champ comme manquant.
      // Maintenant : '' (vide) si pas de valeur côté serveur.
      'typology': raw['typology']?.toString() ?? '',
      'basement': _asBoolInt(raw['basement']),
      'basement_desc': raw['basementDesc']?.toString() ?? '',
      'rdc': _asBoolInt(raw['rdc']),
      'rdc_desc': raw['rdcDesc']?.toString() ?? '',
      'floor': _asBoolInt(raw['floor']),
      'floor_desc': raw['floorDesc']?.toString() ?? '',
      'garage': _asBoolInt(raw['garage']),
      'veranda': _asBoolInt(raw['veranda']),
      'balcon': _asBoolInt(raw['balcon']),
      'terrasse': _asBoolInt(raw['terrasse']),
      'jardin': _asBoolInt(raw['jardin']),
      'heating_details_json': jsonEncode(heatingDetailsJson),
      'volets_roulants_manuels_localisation':
          raw['voletsRoulantsManuelsLocalisation']?.toString() ?? '',
      'volets_roulants_manuels_entier': _asBoolInt(
        raw['voletsRoulantsManuelsEntier'],
      ),
      'volets_roulants_electriques_localisation':
          raw['voletsRoulantsElectriquesLocalisation']?.toString() ?? '',
      'volets_roulants_electriques_entier': _asBoolInt(
        raw['voletsRoulantsElectriquesEntier'],
      ),
      'volets_persiennes_localisation':
          raw['voletsPersiennesLocalisation']?.toString() ?? '',
      'volets_persiennes_entier': _asBoolInt(raw['voletsPersiennesEntier']),
      'cheminement_escalier_exterieur': _asBoolInt(
        raw['cheminementEscalierExterieur'],
      ),
      'cheminement_escalier_interieur': _asBoolInt(
        raw['cheminementEscalierInterieur'],
      ),
      'cheminement_pente_douce': _asBoolInt(raw['cheminementPenteDouce']),
      'cheminement_plat': _asBoolInt(raw['cheminementPlat']),
      'cheminement_quelques_marches': _asBoolInt(
        raw['cheminementQuelquesMarches'],
      ),
      'cheminement_par_arriere': _asBoolInt(raw['cheminementParArriere']),
      'cheminement_seuil_porte': _asBoolInt(raw['cheminementSeuilPorte']),
      'porte_garage_id': raw['porteGarageId']?.toString() ?? '',
      'portail_id': raw['portailId']?.toString() ?? '',
      'motorisation_porte_garage':
          raw['motorisationPorteGarage']?.toString() ?? '',
      'motorisation_portail': raw['motorisationPortail']?.toString() ?? '',
      'easy_access': _asBoolInt(raw['easyAccess']),
      // `easy_access_set` : 1 si NocoDB renvoie une valeur explicitement
      // posée (true/false/0/1/'oui'/'non'), 0 si la clé est absente ou
      // null. Évite la pré-sélection « À revoir » au reload depuis le
      // serveur sur un dossier où l'ergo n'a jamais cliqué (cf. migration
      // v15→v16). NB : NocoDB renvoie `false` par défaut quand la
      // colonne booléenne est nullable et non saisie — ici on traite ce
      // cas comme « non renseigné », même si la valeur arrive en `false`.
      // Si plus tard on a besoin de distinguer false explicite vs absent,
      // il faudra une colonne dédiée côté NocoDB.
      'easy_access_set': raw['easyAccess'] == null ? 0 : 1,
      'comments': raw['comments']?.toString() ?? '',
      'access_observation': raw['accessObservation']?.toString() ?? '',
      // Pièces par niveau — fix 2026-05-07. Le serveur renvoie
      // `roomsBreakdown` (Map) ; on l'éclate en 5 colonnes
      // `*_rooms_json` côté SQLite pour que l'UI (accessibility_tab) lise
      // les pièces par niveau sans changer son code.
      //
      // Si le serveur renvoie `null` (colonne `rooms_breakdown_json` pas
      // encore créée côté NocoDB OU vide), on **NE TOUCHE PAS** aux
      // colonnes locales — c'est le job de `_upsertByLocalId` qui ne
      // mettra pas à jour les colonnes absentes du payload. Donc on
      // omet ces clés du payload quand `roomsBreakdown == null`. Les
      // pièces locales SQLite sont préservées tant que le serveur ne
      // renvoie pas explicitement une valeur.
      ..._extractRoomsBreakdownToColumns(raw['roomsBreakdown']),
      'updated_at': now,
      // Voir _buildDossierPayload : on stocke l'updatedAt serveur, pas
      // l'horodatage local du merge (sert au check optimistic au push).
      'remote_updated_at': _extractRemoteUpdatedAt(raw),
      'sync_state': SyncState.synced.name,
    };
  }

  /// Convertit l'objet `roomsBreakdown` (5 niveaux possibles) en colonnes
  /// `*_rooms_json` SQLite. Renvoie une Map vide si le serveur ne fournit
  /// rien (colonne pas encore en NocoDB) — auquel cas
  /// `_upsertByLocalId` préserve les valeurs locales existantes.
  Map<String, dynamic> _extractRoomsBreakdownToColumns(dynamic raw) {
    if (raw == null) return const {};
    Map<String, dynamic>? map;
    if (raw is Map) {
      map = raw.cast<String, dynamic>();
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) map = decoded.cast<String, dynamic>();
      } catch (_) {}
    }
    if (map == null) return const {};
    String encodeList(dynamic value) {
      if (value is List) {
        return jsonEncode(
          value
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList(),
        );
      }
      return jsonEncode(const <String>[]);
    }

    return {
      'basement_rooms_json': encodeList(map['basement']),
      'rdc_rooms_json': encodeList(map['rdc']),
      'floor_rooms_json': encodeList(map['floor']),
      'second_floor_rooms_json': encodeList(map['secondFloor']),
      'third_floor_rooms_json': encodeList(map['thirdFloor']),
    };
  }

  /// Maps a server-returned dossier JSON to a SQLite row map for `dossiers`.
  Map<String, dynamic> _buildDossierPayload({
    required Map<String, dynamic> raw,
    required String now,
  }) {
    return {
      'status': _asDossierStatusName(raw['status']),
      'ergo_id': raw['ergoId']?.toString() ?? '',
      'visit_date': raw['visitDate']?.toString(),
      'autonomy_notes': raw['autonomyNotes']?.toString() ?? '',
      'compte_anah': raw['compteAnah']?.toString() ?? '',
      'nature_accompagnement': raw['natureAccompagnement']?.toString() ?? '',
      'envoi_rapport': raw['envoiRapport']?.toString() ?? '',
      'personnes_presentes_visite':
          raw['personnesPresentesVisite']?.toString() ?? '',
      if (raw.containsKey('beneficiaryPrepared'))
        'beneficiary_prepared': _asBoolInt(raw['beneficiaryPrepared']),
      'medical_context_json': raw['medicalContext'] is Map
          ? jsonEncode(raw['medicalContext'])
          : null,
      'autonomy_json': raw['autonomy'] is Map
          ? jsonEncode(raw['autonomy'])
          : null,
      'updated_at': now,
      // remote_updated_at = horodatage authoritatif du serveur (et non
      // l'heure locale du merge). Indispensable pour le contrôle
      // d'optimistic concurrency au push : le client renverra cette
      // valeur dans `expectedUpdatedAt` et le serveur (via
      // `sendConflictIfStale`) refusera l'update si quelqu'un d'autre a
      // modifié la ligne entre-temps.
      'remote_updated_at': _extractRemoteUpdatedAt(raw),
      'sync_state': SyncState.synced.name,
    };
  }

  /// Lit le timestamp authoritatif renvoyé par NocoDB pour une row.
  /// Tolère les différentes conventions de nommage rencontrées
  /// (`updatedAt`, `updated_at`, `UpdatedAt`, fallback sur la date de
  /// création quand la row n'a jamais été modifiée).
  String? _extractRemoteUpdatedAt(Map<String, dynamic> raw) {
    for (final key in const [
      'updatedAt',
      'updated_at',
      'UpdatedAt',
      'createdAt',
      'created_at',
      'CreatedAt',
    ]) {
      final v = raw[key];
      if (v != null && v.toString().trim().isNotEmpty) {
        return v.toString();
      }
    }
    return null;
  }

  /// Version globale du payload `/api/dossiers`. Elle sert uniquement à
  /// décider si un pull doit être fusionné. Elle ne doit jamais alimenter
  /// `remote_updated_at`, réservé à la garde optimiste de la row dossier.
  String? _extractWorkspaceUpdatedAt(Map<String, dynamic> raw) {
    final value = raw['workspaceUpdatedAt'];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value.toString();
    }
    return _extractRemoteUpdatedAt(raw);
  }

  // ---------------------------------------------------------------------------
  // Parse helpers (shared by the *Payload builders above)
  // ---------------------------------------------------------------------------

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  }

  double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim().replaceAll(',', '.'));
    return null;
  }

  /// Converts various truthy values (bool, 0/1, "true"/"oui") into SQLite
  /// 0/1 — matching the app's convention for storing booleans.
  int _asBoolInt(dynamic v) {
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v != 0 ? 1 : 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return (s == 'true' || s == '1' || s == 'oui' || s == 'yes') ? 1 : 0;
    }
    return 0;
  }

  String _asHousingTypeName(dynamic typology) {
    final label = typology?.toString().trim() ?? '';
    return label == 'Appartement'
        ? HousingType.APARTMENT.name
        : HousingType.HOUSE.name;
  }

  String _asDossierStatusName(dynamic status) {
    switch (status?.toString()) {
      case 'Validé':
        return DossierStatus.GRANT_VALIDATED.name;
      case 'En cours':
        return DossierStatus.IN_PROGRESS.name;
      case 'Clos':
        return DossierStatus.CLOSED.name;
      case 'À visiter':
      default:
        return DossierStatus.TO_VISIT.name;
    }
  }

  /// Alias kept for the dossier screen's in-place edits. Forwards to
  /// [updatePatient] so we get the same local write + sync-queue behaviour.
  Future<void> updatePatientFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) => updatePatient(patientLocalId, fields);

  Future<void> updateHousingFields(
    String patientLocalId,
    Map<String, dynamic> fields,
  ) async {
    final db = await _database.database;
    fields['updated_at'] = DateTime.now().toIso8601String();
    fields['sync_state'] = SyncState.pendingSync.name;
    await db.update(
      'housings',
      fields,
      where: 'patient_local_id = ?',
      whereArgs: [patientLocalId],
    );
  }

  Future<void> updateDossierFields(
    String dossierLocalId,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    var enqueued = false;

    // L'UPDATE local et l'opération de synchronisation sont atomiques : un
    // arrêt de l'app entre les deux ne peut pas laisser une modification
    // visible uniquement sur cet appareil.
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'dossiers',
        where: 'local_id = ?',
        whereArgs: [dossierLocalId],
        limit: 1,
      );
      final changedFields = _diffAgainstRow(
        existingRows.isEmpty ? null : existingRows.first,
        fields,
      );
      if (changedFields.isEmpty) return;

      final apiUpdates = _mapDossierFieldsToApi(changedFields);
      if (apiUpdates.isEmpty) return;

      final localFields = Map<String, dynamic>.from(changedFields)
        ..['updated_at'] = now
        ..['sync_state'] = SyncState.pendingSync.name;
      await txn.update(
        'dossiers',
        localFields,
        where: 'local_id = ?',
        whereArgs: [dossierLocalId],
      );
      await _enqueueEntityUpdate(
        txn,
        entityType: 'dossier',
        entityLocalId: dossierLocalId,
        localConflict: _formConflict(
          existingRows,
          changedFields,
          observedFields,
        ),
        payloadKey: 'dossierId',
        updates: apiUpdates,
        baseValues: _mapDossierFieldsToApi({
          for (final key in changedFields.keys)
            if (existingRows.isNotEmpty && existingRows.first.containsKey(key))
              key: existingRows.first[key],
        }),
        expectedUpdatedAt: existingRows.isEmpty
            ? null
            : existingRows.first['remote_updated_at'] as String?,
        now: now,
      );
      enqueued = true;
    });
    if (enqueued) SyncEngine().notify();
  }

  static Map<String, dynamic> _mapDossierFieldsToApi(
    Map<String, dynamic> fields,
  ) {
    const snakeToCamel = <String, String>{
      'compte_anah': 'compteAnah',
      'nature_accompagnement': 'natureAccompagnement',
      'envoi_rapport': 'envoiRapport',
      'personnes_presentes_visite': 'personnesPresentesVisite',
      'beneficiary_prepared': 'beneficiaryPrepared',
      'ergo_id': 'ergoId',
      'visit_date': 'visitDate',
      'status': 'status',
    };
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;
      if (snakeToCamel.containsKey(key)) {
        out[snakeToCamel[key]!] = value;
      } else {
        out[key] = value;
      }
    });
    return out;
  }

  /// Refonte 2026-05-16 : accepte `DatabaseExecutor` (commun à `Database`
  /// et `Transaction`) pour permettre aux callers de wrapper le UPDATE
  /// local + l'INSERT sync_op dans une seule transaction atomique (cf.
  /// audit P0 #4 — éviter qu'un crash entre les deux writes ne laisse
  /// une modif locale sans sync_op pour la pousser).
  Future<void> _enqueueEntityUpdate(
    DatabaseExecutor db, {
    required String entityType,
    required String entityLocalId,
    required String payloadKey,
    required Map<String, dynamic> updates,
    required Map<String, dynamic> baseValues,
    required String? expectedUpdatedAt,
    required String now,
    Map<String, dynamic>? localConflict,
  }) async {
    final opId = '${entityType}_update_$entityLocalId';
    final previous = await _readUnconfirmedMutation(db, opId);
    final payloadMap = buildSyncMutation(
      idKey: payloadKey,
      entityId: entityLocalId,
      updates: updates,
      baseValues: baseValues,
      expectedUpdatedAt: expectedUpdatedAt,
      previous: previous,
    );
    if (localConflict != null) {
      payloadMap['conflict'] = {
        ...localConflict,
        if (previous != null) 'previousMutation': previous,
      };
    }
    // Also add a generic local-id key so the housing processor can find
    // the source dossier id (the housing sync needs to resolve the
    // beneficiary from the dossier).
    if (entityType == 'housing') {
      payloadMap['dossierLocalId'] = entityLocalId;
      final guard = (payloadMap['concurrency'] as Map).cast<String, dynamic>();
      if (previous == null && expectedUpdatedAt == null) {
        payloadMap['concurrency'] = {
          ...guard,
          'baseValues': <String, dynamic>{},
          'createIfAbsent': true,
        };
      }
    }
    await db.insert('sync_operations', {
      'id': opId,
      'entity_type': entityType,
      'entity_local_id': entityLocalId,
      'operation_type': 'update',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode(payloadMap),
      ),
      'status': payloadMap.containsKey('conflict') ? 'conflict' : 'pending',
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (payloadMap.containsKey('conflict')) {
      final table = entityType == 'patient'
          ? 'patients'
          : entityType == 'housing'
          ? 'housings'
          : 'dossiers';
      await db.update(
        table,
        {'sync_state': SyncState.conflict.name},
        where: entityType == 'housing'
            ? 'local_id IN (SELECT housing_local_id FROM dossiers WHERE local_id = ?)'
            : 'local_id = ?',
        whereArgs: [entityLocalId],
      );
    }
  }

  /// Child PUT transports still read some fields at the payload root. Keep
  /// that wire shape alongside the canonical mutation and its local reference.
  /// A child version is captured only when that child was actually read.
  Future<void> _enqueueChildUpdate(
    DatabaseExecutor db, {
    required String operationId,
    required String entityType,
    required String dossierId,
    required Map<String, dynamic> updates,
    required Map<String, dynamic> baseValues,
    required Map<String, Object?>? existingRow,
    required String now,
    List<String> rootFields = const [],
  }) async {
    final previous = await _readUnconfirmedMutation(
      db,
      operationId,
      rootFields: rootFields,
    );
    final hasReference =
        previous != null || existingRow?['sync_state'] == SyncState.synced.name;
    final version = existingRow?['remote_updated_at'] as String?;
    final canCaptureVersion =
        _secondaryFields.containsKey(entityType) &&
        previous == null &&
        hasReference &&
        version != null &&
        DateTime.tryParse(version) != null;
    // Legacy queued references must not be upgraded from a newer pull. Their
    // original observation remains unknown until an explicit conflict review.
    final payload = buildSyncMutation(
      idKey: 'dossierId',
      entityId: dossierId,
      updates: updates,
      baseValues: hasReference ? baseValues : {},
      expectedUpdatedAt: canCaptureVersion ? version : null,
      previous: previous == null
          ? null
          : {
              ...previous,
              if (previous['concurrency'] == null)
                'concurrency': previous['localReference'],
            },
    );
    if (previous?['concurrency'] == null && !canCaptureVersion) {
      payload['localReference'] = payload.remove('concurrency');
    }
    if (entityType != 'contexte_de_vie' &&
        _secondaryFields.containsKey(entityType) &&
        previous == null &&
        existingRow == null) {
      payload['concurrency'] = {
        ...(payload.remove('localReference') as Map),
        'createIfAbsent': true,
      };
    }
    if (entityType == 'contexte_de_vie') {
      final previousGuard = previous?['concurrency'];
      final known =
          existingRow?['remote_reference_known'] == 1 || existingRow == null;
      if (previousGuard is Map && previousGuard.containsKey('reference')) {
        payload['concurrency'] = {
          ...((payload['concurrency'] ?? payload.remove('localReference'))
              as Map),
          'reference': previousGuard['reference'],
        };
      } else if (previous == null && known) {
        final reference = existingRow?['remote_reference_json'] as String?;
        payload['concurrency'] = {
          ...(payload.remove('localReference') as Map),
          'reference': reference == null ? null : jsonDecode(reference),
        };
      }
    }
    if (existingRow?['sync_state'] == SyncState.conflict.name) {
      payload.putIfAbsent('conflict', () => <String, dynamic>{});
    }
    for (final key in rootFields) {
      payload[key] = payload['updates'][key];
    }
    final conflicted = payload.containsKey('conflict');
    final oldRows = await db.query(
      'sync_operations',
      where: 'id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    final old = oldRows.isEmpty ? null : oldRows.first;
    await db.insert('sync_operations', {
      'id': operationId,
      'entity_type': entityType,
      'entity_local_id': dossierId,
      'operation_type': 'update',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode(payload),
      ),
      'status': conflicted ? 'conflict' : 'pending',
      'attempt_count': conflicted ? (old?['attempt_count'] ?? 0) : 0,
      'last_error': conflicted ? (old?['last_error']) : null,
      'created_at': previous != null ? (old?['created_at'] ?? now) : now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (conflicted) {
      await db.update(
        entityType,
        {'sync_state': SyncState.conflict.name},
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
      );
    }
  }

  Future<Map<String, dynamic>?> _readUnconfirmedMutation(
    DatabaseExecutor db,
    String operationId, {
    List<String> rootFields = const [],
  }) async {
    final existing = await db.query(
      'sync_operations',
      columns: const ['payload_json', 'status', 'attempt_count'],
      where: 'id = ? AND status IN (?, ?, ?, ?)',
      whereArgs: [
        operationId,
        SyncOperationStatus.pending.name,
        SyncOperationStatus.running.name,
        SyncOperationStatus.failed.name,
        'conflict',
      ],
      limit: 1,
    );
    if (existing.isEmpty) return null;
    // Failure must roll back the save, not silently discard the only copy
    // of an older offline edit whose payload could not be decoded.
    final raw = await OfflineVault.instance.openString(
      existing.first['payload_json'] as String,
    );
    final payload = jsonDecode(raw) as Map<String, dynamic>;
    if (!payload.containsKey('updates') && rootFields.isNotEmpty) {
      if (!rootFields.every((key) => payload[key] is List)) {
        throw const FormatException('Queued mutation has invalid list fields');
      }
      payload['updates'] = {for (final key in rootFields) key: payload[key]};
    }
    if (payload['updates'] is! Map) {
      throw const FormatException('Queued mutation has no valid updates');
    }
    if (!rootFields.every((key) => payload['updates'][key] is List)) {
      throw const FormatException('Queued mutation has invalid list updates');
    }
    if (existing.first['status'] == 'conflict') {
      payload.putIfAbsent('conflict', () => <String, dynamic>{});
    }
    if (payload['concurrency'] is Map &&
        payload['retryMutation'] == null &&
        (existing.first['status'] == 'running' ||
            (existing.first['attempt_count'] as int? ?? 0) > 0)) {
      // An in-flight or uncertain write must be confirmed before its newer
      // coalesced edit can use the server version it produced.
      payload['retryMutation'] = jsonDecode(jsonEncode(payload));
    }
    return payload;
  }

  Future<Map<String, dynamic>> fetchFormData(
    String patientId,
    String formKey,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'note_pages',
      columns: ['text_content'],
      where: 'patient_local_id = ? AND tab_key = ? AND page_number = ?',
      whereArgs: [patientId, 'form_$formKey', 0],
      limit: 1,
    );
    if (rows.isEmpty) return {};
    final text = await OfflineVault.instance.openString(
      rows.first['text_content'] as String? ?? '',
    );
    if (text.isEmpty) return {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<void> saveFormData(
    String patientId,
    String formKey,
    Map<String, dynamic> data,
  ) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final noteId = 'form_${patientId}_$formKey';
    await db.insert('note_pages', {
      'local_id': noteId,
      'patient_local_id': patientId,
      'tab_key': 'form_$formKey',
      'page_number': 0,
      'text_content': await OfflineVault.instance.sealString(jsonEncode(data)),
      'drawing_json': null,
      'drawing_local_path': null,
      'drawing_remote_path': null,
      'drawing_remote_url': null,
      'updated_at': now,
      'sync_state': SyncState.pendingSync.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Dossier _mapDossierRow(Map<String, Object?> row) {
    final trustedPersonJson =
        jsonDecode(row['patient_trusted_person_json'] as String)
            as Map<String, dynamic>;

    // Parse the occupants JSON blob (written by the visit report whenever
    // a per-occupant field is edited). Empty list means "no extra occupant
    // data yet" — the visit report will fall back to derive a single
    // occupant from the top-level patient fields.
    final occupantsRaw = row['patient_occupants_json'] as String? ?? '';
    List<Occupant> occupants = const [];
    if (occupantsRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(occupantsRaw);
        if (decoded is List) {
          occupants = decoded
              .whereType<Map>()
              .map((e) => Occupant.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      } catch (_) {
        // Ignore invalid JSON — fall back to empty list.
      }
    }

    return Dossier(
      id: row['dossier_local_id'] as String,
      patientEditBaseline: Map.unmodifiable({
        for (final entry in row.entries)
          if (entry.key.startsWith('patient_'))
            entry.key.substring('patient_'.length): entry.value,
      }),
      dossierEditBaseline: Map.unmodifiable({
        'personnes_presentes_visite': row['dossier_personnes_presentes'],
        for (final entry in row.entries)
          if (entry.key.startsWith('dossier_'))
            entry.key.substring('dossier_'.length): entry.value,
      }),
      patient: Patient(
        id: row['patient_local_id'] as String,
        firstName: row['patient_first_name'] as String,
        lastName: row['patient_last_name'] as String,
        secondFirstName: row['patient_second_first_name'] as String? ?? '',
        secondLastName: row['patient_second_last_name'] as String? ?? '',
        birthDate: row['patient_birth_date'] as String,
        phone: row['patient_phone'] as String,
        email: row['patient_email'] as String,
        address: row['patient_address'] as String,
        city: row['patient_city'] as String,
        cityId: row['patient_city_id'] as String? ?? '',
        zipCode: row['patient_zip_code'] as String,
        familySituation: row['patient_family_situation'] as String,
        occupationStatus: row['patient_occupation_status'] as String? ?? '',
        incomeCategory: row['patient_income_category'] as String,
        numberPeople: row['patient_number_people'] as int?,
        fiscalRevenue: (row['patient_fiscal_revenue'] as num?)?.toDouble(),
        occupants: occupants,
        apa: (row['patient_apa'] as int? ?? 0) == 1,
        invalidity: (row['patient_invalidity'] as int? ?? 0) == 1,
        invalidityTxt: row['patient_invalidity_txt'] as String? ?? '',
        homeHelp: (row['patient_home_help'] as int? ?? 0) == 1,
        homeHelpTxt: row['patient_home_help_txt'] as String? ?? '',
        dependenceTxt: row['patient_dependence_txt'] as String? ?? '',
        caisseRetraitePrincipale:
            row['patient_caisse_retraite_principale'] as String? ?? '',
        caissesRetraiteComplementaires:
            row['patient_caisses_retraite_complementaires'] as String? ?? '',
        trustedPerson: TrustedPerson(
          name: trustedPersonJson['name'] as String? ?? '',
          phone: trustedPersonJson['phone'] as String? ?? '',
          email: trustedPersonJson['email'] as String? ?? '',
        ),
      ),
      status: DossierStatus.values.byName(row['dossier_status'] as String),
      ergoId: row['dossier_ergo_id'] as String,
      visitDate: row['dossier_visit_date'] as String?,
      compteAnah: row['dossier_compte_anah'] as String? ?? '',
      natureAccompagnement:
          row['dossier_nature_accompagnement'] as String? ?? '',
      envoiRapport: row['dossier_envoi_rapport'] as String? ?? '',
      personnesPresentesVisite:
          row['dossier_personnes_presentes'] as String? ?? '',
      beneficiaryPrepared:
          (row['dossier_beneficiary_prepared'] as int? ?? 0) == 1,
      housing: Housing(
        type: HousingType.values.byName(row['housing_type'] as String),
        year: row['housing_year_value'] as int?,
        surface: (row['housing_surface'] as num?)?.toDouble(),
        heating: HeatingMode.values.byName(
          row['housing_heating_mode'] as String,
        ),
        accessibilityNotes: row['housing_accessibility_notes'] as String,
        yearConstruction: row['housing_year_construction'] as String? ?? '',
        yearHabitation: row['housing_year_habitation'] as String? ?? '',
        levels: row['housing_levels'] as int?,
        // Défaut '' (et pas 'Maison') pour préserver l'état « non
        // renseigné » au reload — voir _buildHousingPayload.
        typology: row['housing_typology'] as String? ?? '',
        basement: (row['housing_basement'] as int? ?? 0) == 1,
        basementDescription: row['housing_basement_desc'] as String? ?? '',
        basementRooms: _decodeRoomsJson(
          row['housing_basement_rooms'] as String?,
        ),
        rdc: (row['housing_rdc'] as int? ?? 0) == 1,
        rdcDescription: row['housing_rdc_desc'] as String? ?? '',
        rdcRooms: _decodeRoomsJson(row['housing_rdc_rooms'] as String?),
        floor: (row['housing_floor'] as int? ?? 0) == 1,
        floorDescription: row['housing_floor_desc'] as String? ?? '',
        floorRooms: _decodeRoomsJson(row['housing_floor_rooms'] as String?),
        secondFloor: (row['housing_second_floor'] as int? ?? 0) == 1,
        secondFloorDescription:
            row['housing_second_floor_desc'] as String? ?? '',
        secondFloorRooms: _decodeRoomsJson(
          row['housing_second_floor_rooms'] as String?,
        ),
        thirdFloor: (row['housing_third_floor'] as int? ?? 0) == 1,
        thirdFloorDescription: row['housing_third_floor_desc'] as String? ?? '',
        thirdFloorRooms: _decodeRoomsJson(
          row['housing_third_floor_rooms'] as String?,
        ),
        garage: (row['housing_garage'] as int? ?? 0) == 1,
        veranda: (row['housing_veranda'] as int? ?? 0) == 1,
        balcon: (row['housing_balcon'] as int? ?? 0) == 1,
        terrasse: (row['housing_terrasse'] as int? ?? 0) == 1,
        jardin: (row['housing_jardin'] as int? ?? 0) == 1,
        heatingDetails: _decodeHeatingDetails(
          row['housing_heating_details'] as String?,
        ),
        voletsRoulantsManuelsLocalisation:
            row['housing_volets_man_loc'] as String? ?? '',
        voletsRoulantsManuelsEntier:
            (row['housing_volets_man_entier'] as int? ?? 0) == 1,
        voletsRoulantsElectriquesLocalisation:
            row['housing_volets_elec_loc'] as String? ?? '',
        voletsRoulantsElectriquesEntier:
            (row['housing_volets_elec_entier'] as int? ?? 0) == 1,
        voletsPersiennesLocalisation:
            row['housing_volets_pers_loc'] as String? ?? '',
        voletsPersiennesEntier:
            (row['housing_volets_pers_entier'] as int? ?? 0) == 1,
        porteGarageId: row['housing_porte_garage_id'] as String? ?? '',
        portailId: row['housing_portail_id'] as String? ?? '',
        motorisationPorteGarage:
            row['housing_motorisation_porte_garage'] as String? ?? '',
        motorisationPortail:
            row['housing_motorisation_portail'] as String? ?? '',
        easyAccess: (row['housing_easy_access'] as int? ?? 0) == 1,
        comments: row['housing_comments'] as String? ?? '',
        accessObservation: row['housing_access_observation'] as String? ?? '',
      ),
      autonomyNotes: row['dossier_autonomy_notes'] as String,
      plans: const {
        'PF1': FinancialPlan(id: 'PF1'),
        'PF2': FinancialPlan(id: 'PF2'),
        'PF3': FinancialPlan(id: 'PF3'),
      },
      createdAt: row['dossier_created_at'] as String,
      // Aggregate sync_state across dossier + patient + housing.
      // Without this, un patient en `conflict` mais dont la ligne
      // `dossiers` est `synced` ne déclenchait pas le bouton « Résoudre
      // le conflit » de DossierScreen → l'ergo restait coincé sur des
      // données stale (ex. macOS qui montre encore « Joris SAH » alors
      // que NocoDB a « Joris SIM »). Demande utilisateur 2026-04-30.
      // Priorité : conflict > failed > pendingSync > localOnly > synced.
      syncState: _aggregateSyncStates([
        if (row['child_conflict'] == 1) SyncState.conflict,
        SyncState.values.byName(row['dossier_sync_state'] as String),
        SyncState.values.byName(
          row['patient_sync_state'] as String? ?? SyncState.synced.name,
        ),
        SyncState.values.byName(
          row['housing_sync_state'] as String? ?? SyncState.synced.name,
        ),
      ]),
    );
  }

  /// Aggregate plusieurs sync_state en un seul, en priorisant l'état le
  /// plus « urgent » à remonter à l'utilisateur :
  ///   conflict > syncError > pendingSync > syncing > localOnly > synced
  ///
  /// Permet à `DossierScreen` de surfacer le bouton « Résoudre le
  /// conflit » même quand seul le sous-record (patient ou housing) est
  /// en conflit, pas le dossier lui-même.
  static SyncState _aggregateSyncStates(List<SyncState> states) {
    if (states.contains(SyncState.conflict)) return SyncState.conflict;
    if (states.contains(SyncState.syncError)) return SyncState.syncError;
    if (states.contains(SyncState.pendingSync)) return SyncState.pendingSync;
    if (states.contains(SyncState.syncing)) return SyncState.syncing;
    if (states.contains(SyncState.localOnly)) return SyncState.localOnly;
    return SyncState.synced;
  }

  List<String> _decodeRoomsJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.map((e) => e.toString()).toList(growable: false);
      }
    } catch (_) {
      /* fall through */
    }
    return const [];
  }

  Map<String, bool> _decodeHeatingDetails(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v == true));
      }
    } catch (_) {
      /* fall through */
    }
    return const {};
  }

  // ---------------------------------------------------------------------------
  // Visit report CRUD methods
  // ---------------------------------------------------------------------------

  /// Updates a patient's fields both locally AND enqueues a remote sync
  /// operation so NocoDB receives the change when the device is online.
  ///
  /// [fields] can mix SQL column names (snake_case like `first_name`,
  /// `trusted_person_json`) — they are translated to the API's camelCase
  /// payload keys (`firstName`, `trustedPerson: {…}`, …) before being
  /// enqueued. Unknown snake_case keys are passed through as-is.
  Future<void> updatePatient(
    String patientId,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    var enqueued = false;

    // Read, diff, baseline and queued mutation share the same transaction:
    // a workspace pull cannot change the reference between these steps.
    await db.transaction((txn) async {
      final existingRows = await txn.query(
        'patients',
        where: 'local_id = ?',
        whereArgs: [patientId],
        limit: 1,
      );
      final changedFields = _diffAgainstRow(
        existingRows.isEmpty ? null : existingRows.first,
        fields,
      );

      if (changedFields.isEmpty) {
        // Aucun champ n'a changé — on évite l'écriture locale, la mise
        // à jour de `updated_at`, et le push serveur. Idempotent : si
        // l'utilisateur tape un caractère puis efface, on ne fait rien.
        return;
      }

      final apiUpdates = _mapPatientFieldsToApi(changedFields);
      final localFields = Map<String, dynamic>.from(changedFields);
      localFields['updated_at'] = now;
      localFields['sync_state'] = SyncState.pendingSync.name;
      await txn.update(
        'patients',
        localFields,
        where: 'local_id = ?',
        whereArgs: [patientId],
      );

      // Si aucun champ ne se traduit en API payload, on saute juste
      // l'enqueue — le UPDATE local reste committé (cas rare : champ
      // local-only modifié).
      if (apiUpdates.isEmpty) return;

      await _enqueueEntityUpdate(
        txn,
        entityType: 'patient',
        entityLocalId: patientId,
        localConflict: _formConflict(
          existingRows,
          changedFields,
          observedFields,
        ),
        payloadKey: 'patientLocalId',
        updates: apiUpdates,
        baseValues: _mapPatientFieldsToApi({
          for (final key in changedFields.keys)
            if (existingRows.isNotEmpty && existingRows.first.containsKey(key))
              key: existingRows.first[key],
        }),
        expectedUpdatedAt: existingRows.isEmpty
            ? null
            : existingRows.first['remote_updated_at'] as String?,
        now: now,
      );
      enqueued = true;
    });
    if (enqueued) SyncEngine().notify();
  }

  Map<String, dynamic>? _formConflict(
    List<Map<String, Object?>> rows,
    Map<String, dynamic> changes,
    Map<String, dynamic>? observed,
  ) {
    if (observed == null || rows.isEmpty) return null;
    final current = rows.first;
    final fields = <String, dynamic>{
      for (final key in changes.keys)
        if (observed.containsKey(key) &&
            _fieldChanged(observed[key], current[key]))
          key: {'observed': observed[key], 'current': current[key]},
    };
    if (fields.isEmpty) return null;
    return {'code': 'LOCAL_EDIT_BASE_CHANGED', 'fields': fields};
  }

  /// Compare une valeur existante (lue depuis SQLite) avec une nouvelle
  /// valeur candidate (issue du form Flutter). Renvoie `true` si elles
  /// sont fonctionnellement différentes du point de vue d'un push API.
  ///
  /// Normalise quelques cas piégeux :
  ///   - Booléen Dart vs INT SQLite 0/1 : `false` == `0` et `true` == `1`
  ///   - Nombres : `12000` (int) == `12000.0` (double) — pas de mismatch
  ///     type spurious quand SQLite stocke en REAL ce que Dart envoie
  ///     en int et inversement
  ///   - `null` vs `""` : considérés équivalents — l'utilisateur qui
  ///     efface un champ vide ne déclenche pas un push inutile
  ///   - Tout le reste : comparaison `.toString()` (couvre les String,
  ///     les JSON encoded `*_json`, etc.)
  ///
  /// Helper générique partagé entre updatePatient / updateHousing /
  /// updateMesures / updateObservations / updateContexteDeVie — chacun
  /// appelle ce helper pour ne pousser que les champs qui ont vraiment
  /// changé depuis la dernière écriture SQLite.
  static bool _fieldChanged(dynamic existing, dynamic candidate) {
    // Bool Dart côté candidate, INT 0/1 côté SQLite
    if (candidate is bool) {
      if (existing is int) return existing != (candidate ? 1 : 0);
      if (existing is bool) return existing != candidate;
      // type mismatch → on considère différent par sécurité
      return existing != null;
    }
    // Nombres : compare en double pour absorber int<->double
    if (candidate is num && existing is num) {
      return candidate.toDouble() != existing.toDouble();
    }
    // Normalize null/empty → '' pour traiter les deux comme équivalents
    final a = existing == null ? '' : existing.toString();
    final b = candidate == null ? '' : candidate.toString();
    return a != b;
  }

  /// Filtre [candidateFields] en ne gardant que les clés dont la valeur
  /// diffère de la row [existing] (lue depuis SQLite). Utilisé par tous
  /// les update* du repository pour éviter de pousser des champs intacts
  /// vers le serveur.
  static Map<String, dynamic> _diffAgainstRow(
    Map<String, dynamic>? existing,
    Map<String, dynamic> candidateFields,
  ) {
    if (existing == null) return candidateFields;
    final diff = <String, dynamic>{};
    candidateFields.forEach((key, value) {
      if (_fieldChanged(existing[key], value)) {
        diff[key] = value;
      }
    });
    return diff;
  }

  /// Maps SQL column names (snake_case) used by the visit-report tabs to
  /// the camelCase keys expected by the Express API. Also decodes JSON
  /// blobs (trusted_person_json, occupants_json) into nested structures.
  static Map<String, dynamic> _mapPatientFieldsToApi(
    Map<String, dynamic> fields,
  ) {
    const snakeToCamel = <String, String>{
      'first_name': 'firstName',
      'last_name': 'lastName',
      'second_first_name': 'secondFirstName',
      'second_last_name': 'secondLastName',
      'birth_date': 'occupant1BirthDate',
      'phone': 'phone',
      'email': 'email',
      'address': 'address',
      'city': 'city',
      'city_id': 'cityId',
      'zip_code': 'zipCode',
      'family_situation': 'familySituation',
      'occupation_status': 'occupationStatus',
      'income_category': 'incomeCategory',
      'fiscal_revenue': 'fiscalRevenue',
      'number_people': 'numberPeople',
      'invalidity_txt': 'invalidityTxt',
      'home_help_txt': 'homeHelpTxt',
      'dependence_txt': 'dependenceTxt',
      'caisse_retraite_principale': 'caisseRetraitePrincipale',
      'caisses_retraite_complementaires': 'caissesRetraiteComplementaires',
    };
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;
      if (snakeToCamel.containsKey(key)) {
        out[snakeToCamel[key]!] = value;
        return;
      }
      // Booleans stored as 0/1 in SQLite — decode back to bool for the API.
      if (key == 'apa' || key == 'invalidity' || key == 'home_help') {
        final camel = {
          'apa': 'apa',
          'invalidity': 'invalidity',
          'home_help': 'homeHelp',
        }[key]!;
        out[camel] = value == 1 || value == true;
        return;
      }
      if (key == 'trusted_person_json' && value is String && value.isNotEmpty) {
        try {
          out['trustedPerson'] = jsonDecode(value);
        } catch (_) {}
        return;
      }
      if (key == 'occupants_json' && value is String && value.isNotEmpty) {
        try {
          out['occupants'] = jsonDecode(value);
        } catch (_) {}
        return;
      }
      // Pass-through (rare): already camelCase or unknown.
      out[key] = value;
    });
    return out;
  }

  /// Loads the raw housing row (all columns) for a given dossier id. Used by
  /// the accessibility tab to access per-level rooms (stored as JSON),
  /// second/third-floor flags and all extended fields that aren't exposed
  /// on the [Housing] model.
  Future<Map<String, dynamic>?> fetchHousingRaw(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'dossiers',
      columns: ['housing_local_id'],
      where: 'local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final housingId = rows.first['housing_local_id'] as String;
    final housing = await db.query(
      'housings',
      where: 'local_id = ?',
      whereArgs: [housingId],
      limit: 1,
    );
    if (housing.isEmpty) return null;
    return Map<String, dynamic>.from(housing.first);
  }

  static const List<String> _kHousingRoomBreakdownColumns = [
    'basement_rooms_json',
    'rdc_rooms_json',
    'floor_rooms_json',
    'second_floor_rooms_json',
    'third_floor_rooms_json',
  ];

  static void _expandChangedRoomBreakdownFields(
    Map<String, dynamic> changedFields,
    Map<String, dynamic> candidateFields,
    Map<String, dynamic>? existingRow,
  ) {
    final roomChanged = _kHousingRoomBreakdownColumns.any(
      changedFields.containsKey,
    );
    if (!roomChanged) return;

    // L'API stocke les pièces des niveaux dans un seul JSON
    // `roomsBreakdown`. Si un seul niveau change, on ajoute les autres
    // niveaux inchangés pour éviter de remplacer le JSON distant par un
    // objet partiel.
    for (final col in _kHousingRoomBreakdownColumns) {
      if (changedFields.containsKey(col)) continue;
      if (candidateFields.containsKey(col)) {
        changedFields[col] = candidateFields[col];
      } else if (existingRow != null && existingRow.containsKey(col)) {
        changedFields[col] = existingRow[col];
      }
    }
  }

  Future<void> updateHousing(
    String dossierId,
    Map<String, dynamic> fields,
  ) async {
    final db = await _database.database;
    var enqueued = false;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'dossiers',
        columns: ['housing_local_id'],
        where: 'local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final housingId = rows.first['housing_local_id'] as String;
      final now = DateTime.now().toIso8601String();

      // Lecture row SQLite locale pour calculer un vrai PATCH partiel.
      // L'ancien code repoussait systématiquement les booléens et les
      // champs critiques du logement à chaque save Accessibilité. C'était
      // défensif après un ancien bug serveur, mais le serveur respecte
      // maintenant `undefined` comme "ne pas toucher". On peut donc
      // alléger fortement la sync sans risque d'effacer les champs absents.
      final existingRows = await txn.query(
        'housings',
        where: 'local_id = ?',
        whereArgs: [housingId],
        limit: 1,
      );
      final existingRow = existingRows.isEmpty ? null : existingRows.first;

      final changedFields = _diffAgainstRow(existingRow, fields);
      _expandChangedRoomBreakdownFields(changedFields, fields, existingRow);

      if (changedFields.isEmpty) {
        return; // rien n'a vraiment changé → no-op
      }

      // Conversion bool→int pour SQLite (fix 2026-05-15).
      final localFields = <String, dynamic>{};
      for (final entry in changedFields.entries) {
        final v = entry.value;
        localFields[entry.key] = v is bool ? (v ? 1 : 0) : v;
      }
      localFields['updated_at'] = now;
      localFields['sync_state'] = SyncState.pendingSync.name;

      // Refonte 2026-05-16 (audit P0 #4) : UPDATE + INSERT sync_op
      // dans une seule transaction atomique. Si l'app crash entre les
      // deux writes, SQLite rollback complet → pas d'état orphelin.
      final apiUpdates = _mapHousingFieldsToApi(changedFields);
      await txn.update(
        'housings',
        localFields,
        where: 'local_id = ?',
        whereArgs: [housingId],
      );
      if (apiUpdates.isEmpty) return;
      await _enqueueEntityUpdate(
        txn,
        entityType: 'housing',
        entityLocalId: dossierId,
        payloadKey: 'dossierLocalId',
        updates: apiUpdates,
        baseValues: _mapHousingFieldsToApi({
          for (final key in changedFields.keys)
            if (existingRow != null && existingRow.containsKey(key))
              key: existingRow[key],
        }),
        expectedUpdatedAt: existingRow?['remote_updated_at'] as String?,
        now: now,
      );
      enqueued = true;
    });
    if (enqueued) SyncEngine().notify();
  }

  static Map<String, dynamic> _mapHousingFieldsToApi(
    Map<String, dynamic> fields,
  ) {
    // PATCH /api/logements server-side reads :
    //   - les champs simples en camelCase : `yearConstruction`,
    //     `voletsRoulantsManuelsEntier`, `voletsRoulantsManuelsLocalisation`,
    //     `cheminementEscalierExterieur`, …
    //   - le chauffage en objet structuré `heatingDetails: { electric,
    //     gas, oil, heatPump, collective, wood, pellet, other }`
    //
    // Notre côté Flutter écrit en SQLite avec les noms de colonnes
    // SQL (snake_case + `heating_details_json` JSON-encoded). Avant ce
    // mapping correct, le mapper laissait passer les clés snake_case
    // quasi-telles-quelles → le serveur recevait `undefined` pour
    // toutes ces clés → écriture NocoDB vide → au pull workspace
    // suivant le local était écrasé par le vide → l'ergo voyait ses
    // chauffages + volets RESET à chaque rechargement de l'app.
    const snakeToCamel = <String, String>{
      'year_construction': 'yearConstruction',
      'year_habitation': 'yearHabitation',
      'surface': 'surface',
      'levels': 'levels',
      'typology': 'typology',
      'easy_access': 'easyAccess',
      'access_observation': 'accessObservation',
      'motorisation_porte_garage': 'motorisationPorteGarage',
      'motorisation_portail': 'motorisationPortail',
      // Volets — 6 clés (3 types × 2 champs entier/localisation).
      'volets_roulants_manuels_entier': 'voletsRoulantsManuelsEntier',
      'volets_roulants_manuels_localisation':
          'voletsRoulantsManuelsLocalisation',
      'volets_roulants_electriques_entier': 'voletsRoulantsElectriquesEntier',
      'volets_roulants_electriques_localisation':
          'voletsRoulantsElectriquesLocalisation',
      'volets_persiennes_entier': 'voletsPersiennesEntier',
      'volets_persiennes_localisation': 'voletsPersiennesLocalisation',
      // Annexes (boolean) — connues du serveur sous le même nom snake_case.
      // Le `else` du forEach les passe correctement, mais on est plus
      // explicite ici.
      // Cheminement (boolean).
      'cheminement_escalier_exterieur': 'cheminementEscalierExterieur',
      'cheminement_escalier_interieur': 'cheminementEscalierInterieur',
      'cheminement_pente_douce': 'cheminementPenteDouce',
      'cheminement_plat': 'cheminementPlat',
      'cheminement_quelques_marches': 'cheminementQuelquesMarches',
      'cheminement_par_arriere': 'cheminementParArriere',
      'cheminement_seuil_porte': 'cheminementSeuilPorte',
      // Niveaux multiples : `basement`, `rdc`, `floor` sont déjà
      // camelCase-équivalents (envoyés tels quels). `second_floor` et
      // `third_floor` doivent être convertis en `secondFloor` /
      // `thirdFloor` pour matcher la signature serveur
      // (`updates.secondFloor` côté server/index.mjs). Ces deux clés
      // alimentent les colonnes NocoDB `second_etage` et `third_etage`,
      // utilisées par le générateur PDF pour dupliquer la ligne
      // « Étage » en « Étage 1 / 2 / 3 » page 5 (demande utilisateur
      // 2026-04-29).
      'second_floor': 'secondFloor',
      'third_floor': 'thirdFloor',
      // Descriptions des niveaux — alimentées en Flutter à partir
      // des `*_rooms_json` (cf. accessibility_tab._save). Mappées vers
      // les colonnes NocoDB `description_sous_sol` / `description_rdc`
      // / `description_etage` (cf. PATCH /api/logements server-side).
      'basement_desc': 'basementDesc',
      'rdc_desc': 'rdcDesc',
      'floor_desc': 'floorDesc',
      // second_floor_desc et third_floor_desc : pas de colonne NocoDB
      // dédiée pour le moment, on les ignore au mapping API (le `else`
      // les passerait en snake_case et le serveur les ignorerait
      // silencieusement, mais autant être explicite).
    };
    // Mapping rooms_json (5 niveaux) → 1 seul champ `roomsBreakdown` côté
    // serveur (cf. fix 2026-05-07 : les `*_rooms_json` n'étaient pas
    // persistés en NocoDB, donc perdus au moindre wipe SQLite). Map
    // serveur prend le clé Flutter UI / serveur → clé courte du JSON.
    const roomsJsonToBreakdownKey = <String, String>{
      'basement_rooms_json': 'basement',
      'rdc_rooms_json': 'rdc',
      'floor_rooms_json': 'floor',
      'second_floor_rooms_json': 'secondFloor',
      'third_floor_rooms_json': 'thirdFloor',
    };
    final roomsBreakdown = <String, List<String>>{};
    final out = <String, dynamic>{};
    fields.forEach((key, value) {
      if (key == 'updated_at' || key == 'sync_state') return;

      // Pièces par niveau : on agrège les 5 *_rooms_json en un objet
      // `roomsBreakdown` envoyé en bloc au serveur. Décode chaque
      // valeur (JSON list de strings) ; si malformé, on ignore.
      if (roomsJsonToBreakdownKey.containsKey(key)) {
        final breakdownKey = roomsJsonToBreakdownKey[key]!;
        if (value is String && value.isNotEmpty) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is List) {
              roomsBreakdown[breakdownKey] = decoded
                  .map((e) => e?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList();
            }
          } catch (_) {
            // JSON malformé → on n'ajoute pas cette clé.
          }
        } else {
          // Valeur vide / null → niveau désactivé, on transmet une
          // liste vide pour explicitement vider côté serveur (sinon
          // l'ancienne valeur reste).
          roomsBreakdown[breakdownKey] = const [];
        }
        return;
      }
      // `easy_access_set` est local-only (migration v15→v16). NocoDB n'a
      // pas de colonne dédiée — on garde la sémantique « non renseigné »
      // côté Flutter uniquement. Si plus tard on veut propager la
      // distinction, ajouter une colonne `easy_access_set` (Checkbox)
      // côté serveur et mettre à jour ce mapping.
      if (key == 'easy_access_set') return;

      // Cas spécial : `heating_details_json` est un JSON encodé
      // (Map<String label, bool>). On le décode et on le convertit
      // au format structuré attendu par le serveur :
      // `heatingDetails: { electric, gas, oil, heatPump, collective,
      // wood, pellet, other }`.
      if (key == 'heating_details_json') {
        if (value is String && value.isNotEmpty) {
          try {
            final decoded = jsonDecode(value);
            if (decoded is Map) {
              out['heatingDetails'] = {
                'electric': decoded['Électrique'] == true,
                'gas': decoded['Gaz'] == true,
                'oil': decoded['Fioul'] == true,
                'heatPump':
                    decoded['Pompe à chaleur'] == true ||
                    decoded['PAC'] == true,
                'collective': decoded['Collectif'] == true,
                'wood': decoded['Bois'] == true,
                'pellet': decoded['Granulés'] == true,
                'other': decoded['Autre'] == true,
              };
            }
          } catch (_) {
            // JSON malformé — on ne pousse rien plutôt que d'écraser
            // les données serveur avec du vide.
          }
        }
        return;
      }

      if (snakeToCamel.containsKey(key)) {
        // Cas spécial easy_access : stocké en int 0/1 côté SQLite,
        // attendu en bool côté API.
        if (key == 'easy_access' && value is int) {
          out[snakeToCamel[key]!] = value == 1;
        } else {
          out[snakeToCamel[key]!] = value;
        }
      } else {
        // Pass boolean-ish integer columns as bool where obvious.
        if (value is int && (value == 0 || value == 1)) {
          out[key] = value == 1;
        } else {
          out[key] = value;
        }
      }
    });
    // Si au moins un *_rooms_json a été traité, on attache l'objet
    // `roomsBreakdown` au payload sortant. NB : on attache MÊME quand
    // toutes les listes sont vides — c'est le moyen explicite de
    // « vider » les pièces côté serveur (ex. niveau désactivé).
    if (roomsBreakdown.isNotEmpty) {
      out['roomsBreakdown'] = roomsBreakdown;
    }
    return out;
  }

  Future<Map<String, dynamic>?> fetchContexteDeVie(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'contexte_de_vie',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'medicalContext': row['medical_context_json'] != null
          ? jsonDecode(row['medical_context_json'] as String)
          : null,
      'autonomy': row['autonomy_json'] != null
          ? jsonDecode(row['autonomy_json'] as String)
          : null,
    };
  }

  Future<void> upsertContexteDeVie(
    String dossierId,
    String patientId, {
    MedicalContext? medicalContext,
    AutonomyData? autonomy,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'contexte_de_vie',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );

      // Optimisation 2026-05-13 : on compare le JSON encoded des sous-
      // objets `medicalContext` et `autonomy` avec ce qui est déjà en
      // SQLite. Si le JSON est identique → on ne push pas. Avant ce
      // changement, chaque toggle de case Médical ou Autonomie poussait
      // les 2 objets ENTIERS à NocoDB (objets de 20+ champs chacun).
      final newMedicalJson = medicalContext != null
          ? jsonEncode(medicalContext.toJson())
          : null;
      final newAutonomyJson = autonomy != null
          ? jsonEncode(autonomy.toJson())
          : null;

      final existingRow = existing.isNotEmpty ? existing.first : null;
      final existingMedicalJson =
          existingRow?['medical_context_json'] as String?;
      final existingAutonomyJson = existingRow?['autonomy_json'] as String?;

      final medicalChanged =
          newMedicalJson != null &&
          _fieldChanged(existingMedicalJson, newMedicalJson);
      final autonomyChanged =
          newAutonomyJson != null &&
          _fieldChanged(existingAutonomyJson, newAutonomyJson);

      if (!medicalChanged && !autonomyChanged) {
        // Aucun des 2 objets n'a vraiment changé → no-op total.
        return;
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'patient_local_id': patientId,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };
      if (medicalChanged) data['medical_context_json'] = newMedicalJson;
      if (autonomyChanged) data['autonomy_json'] = newAutonomyJson;

      final opUpdates = <String, dynamic>{};
      if (medicalChanged && medicalContext != null) {
        opUpdates['medicalContext'] = medicalContext.toJson();
      }
      if (autonomyChanged && autonomy != null) {
        opUpdates['autonomy'] = autonomy.toJson();
      }

      if (existing.isEmpty) {
        data['local_id'] = 'ctx_${dossierId}_${_uuid()}';
        await txn.insert('contexte_de_vie', data);
      } else {
        await txn.update(
          'contexte_de_vie',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }

      if (opUpdates.isEmpty) return;

      final opId = 'contexte_update_$dossierId';
      await _enqueueChildUpdate(
        txn,
        operationId: opId,
        entityType: 'contexte_de_vie',
        dossierId: dossierId,
        updates: opUpdates,
        baseValues: {
          if (medicalChanged && existingMedicalJson != null)
            'medicalContext': jsonDecode(existingMedicalJson),
          if (autonomyChanged && existingAutonomyJson != null)
            'autonomy': jsonDecode(existingAutonomyJson),
        },
        existingRow: existingRow,
        now: now,
      );
    });
    SyncEngine().notify();
  }

  Future<DiagnosticSanitaire?> fetchDiagnosticSanitaire(
    String dossierId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'diagnostic_sanitaires',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DiagnosticSanitaire(
      dossierId: dossierId,
      sdbInstances: row['sdb_instances_json'] != null
          ? (jsonDecode(row['sdb_instances_json'] as String) as List<dynamic>)
                .map(
                  (e) => BathroomInstance.fromJson(e as Map<String, dynamic>),
                )
                .toList()
          : [],
      wcInstances: row['wc_instances_json'] != null
          ? (jsonDecode(row['wc_instances_json'] as String) as List<dynamic>)
                .map((e) => WcInstance.fromJson(e as Map<String, dynamic>))
                .toList()
          : [],
    );
  }

  Future<void> upsertDiagnosticSanitaire(
    String dossierId,
    DiagnosticSanitaire diag,
  ) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'diagnostic_sanitaires',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      final sdbJson = diag.sdbInstances.map((e) => e.toJson()).toList();
      final wcJson = diag.wcInstances.map((e) => e.toJson()).toList();
      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'sdb_instances_json': jsonEncode(sdbJson),
        'wc_instances_json': jsonEncode(wcJson),
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };

      if (existing.isEmpty) {
        data['local_id'] = 'diag_${dossierId}_${_uuid()}';
        await txn.insert('diagnostic_sanitaires', data);
      } else {
        await txn.update(
          'diagnostic_sanitaires',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      final row = existing.isEmpty ? null : existing.first;
      await _enqueueChildUpdate(
        txn,
        operationId: 'diag_update_$dossierId',
        entityType: 'diagnostic_sanitaires',
        dossierId: dossierId,
        updates: {'sdbInstances': sdbJson, 'wcInstances': wcJson},
        baseValues: {
          if (row?['sdb_instances_json'] != null)
            'sdbInstances': jsonDecode(row!['sdb_instances_json'] as String),
          if (row?['wc_instances_json'] != null)
            'wcInstances': jsonDecode(row!['wc_instances_json'] as String),
        },
        existingRow: row,
        rootFields: const ['sdbInstances', 'wcInstances'],
        now: now,
      );
    });
    SyncEngine().notify();
  }

  /// Removes sanitary details whose room no longer exists in Accessibility.
  ///
  /// Housing rooms are the source of truth for bathroom/WC instances. Keeping
  /// an old instance after its room was removed would make it reappear in the
  /// generated report and on another device after synchronization.
  Future<void> pruneDiagnosticSanitaireForRooms(
    String dossierId, {
    required Set<String> bathroomLevelFields,
    required Set<String> wcLevelFields,
  }) async {
    final current = await fetchDiagnosticSanitaire(dossierId);
    if (current == null) return;

    final bathrooms = current.sdbInstances
        .where((instance) => bathroomLevelFields.contains(instance.levelField))
        .toList();
    final toilets = current.wcInstances
        .where((instance) => wcLevelFields.contains(instance.levelField))
        .toList();
    if (bathrooms.length == current.sdbInstances.length &&
        toilets.length == current.wcInstances.length) {
      return;
    }

    await upsertDiagnosticSanitaire(
      dossierId,
      DiagnosticSanitaire(
        dossierId: dossierId,
        sdbInstances: bathrooms,
        wcInstances: toilets,
      ),
    );
  }

  Future<MesuresAnthropometriques?> fetchMesures(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'mesures_anthropometriques',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return MesuresAnthropometriques(
      dossierId: dossierId,
      deboutHauteurCoude: (row['debout_hauteur_coude'] as num?)?.toDouble(),
      assisHauteurAssise: (row['assis_hauteur_assise'] as num?)?.toDouble(),
      assisProfondeurGenoux: (row['assis_profondeur_genoux'] as num?)
          ?.toDouble(),
      assisHauteurCoudes: (row['assis_hauteur_coudes'] as num?)?.toDouble(),
      observations: row['observations'] as String? ?? '',
    );
  }

  Future<void> upsertMesures(
    String dossierId,
    MesuresAnthropometriques mesures,
  ) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'mesures_anthropometriques',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );

      // Optimisation 2026-05-13 : diff avec la row existante pour ne
      // pousser au serveur QUE les champs réellement modifiés. Si l'ergo
      // tape juste un caractère dans "Hauteur assise" puis stabilise, on
      // ne push QUE `assisHauteurAssise` au lieu des 5 champs mesures.
      final fieldCandidates = <String, dynamic>{
        'debout_hauteur_coude': mesures.deboutHauteurCoude,
        'assis_hauteur_assise': mesures.assisHauteurAssise,
        'assis_profondeur_genoux': mesures.assisProfondeurGenoux,
        'assis_hauteur_coudes': mesures.assisHauteurCoudes,
        'observations': mesures.observations,
      };
      final changedFields = _diffAgainstRow(
        existing.isEmpty ? null : existing.first,
        fieldCandidates,
      );

      if (changedFields.isEmpty && existing.isNotEmpty) {
        // Aucun champ modifié, et la row existe déjà → no-op.
        // (Si la row n'existe pas, on doit créer une row même avec des
        // valeurs vides pour avoir une cible d'update future.)
        return;
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        ...changedFields,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };
      // Mapping snake→camel pour l'API. On ne push QUE les champs qui
      // ont changé (cf. `changedFields` ci-dessus).
      const snakeToCamel = <String, String>{
        'debout_hauteur_coude': 'deboutHauteurCoude',
        'assis_hauteur_assise': 'assisHauteurAssise',
        'assis_profondeur_genoux': 'assisProfondeurGenoux',
        'assis_hauteur_coudes': 'assisHauteurCoudes',
        'observations': 'observations',
      };
      final updates = <String, dynamic>{};
      changedFields.forEach((snake, value) {
        final camel = snakeToCamel[snake];
        if (camel != null) updates[camel] = value;
      });

      if (existing.isEmpty) {
        data
          ..['debout_hauteur_coude'] = mesures.deboutHauteurCoude
          ..['assis_hauteur_assise'] = mesures.assisHauteurAssise
          ..['assis_profondeur_genoux'] = mesures.assisProfondeurGenoux
          ..['assis_hauteur_coudes'] = mesures.assisHauteurCoudes
          ..['observations'] = mesures.observations
          ..['local_id'] = 'mes_${dossierId}_${_uuid()}';
        await txn.insert('mesures_anthropometriques', data);
      } else {
        await txn.update(
          'mesures_anthropometriques',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }

      if (updates.isEmpty) return;
      final opId = 'mesures_update_$dossierId';
      await _enqueueChildUpdate(
        txn,
        operationId: opId,
        entityType: 'mesures_anthropometriques',
        dossierId: dossierId,
        updates: updates,
        baseValues: {
          for (final key in changedFields.keys)
            if (existing.isNotEmpty && snakeToCamel.containsKey(key))
              snakeToCamel[key]!: existing.first[key],
        },
        existingRow: existing.isEmpty ? null : existing.first,
        now: now,
      );
    });
    SyncEngine().notify();
  }

  Future<ObservationsSynthese?> fetchObservations(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'observations_synthese',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ObservationsSynthese(
      dossierId: dossierId,
      observationEquipements: row['observation_equipements'] as String? ?? '',
      projetSouhaitUsage: row['projet_souhait_usage'] as String? ?? '',
      resumePreconisations: row['resume_preconisations'] as String? ?? '',
    );
  }

  Future<void> upsertObservations(
    String dossierId,
    ObservationsSynthese obs,
  ) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'observations_synthese',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );

      // Optimisation 2026-05-13 : diff pattern aligné sur upsertMesures.
      final fieldCandidates = <String, dynamic>{
        'observation_equipements': obs.observationEquipements,
        'projet_souhait_usage': obs.projetSouhaitUsage,
        'resume_preconisations': obs.resumePreconisations,
      };
      final changedFields = _diffAgainstRow(
        existing.isEmpty ? null : existing.first,
        fieldCandidates,
      );

      if (changedFields.isEmpty && existing.isNotEmpty) {
        return; // rien changé + row existe → no-op
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        ...changedFields,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };
      // Pattern aligné sur `upsertContexteDeVie`.
      const snakeToCamel = <String, String>{
        'observation_equipements': 'observationEquipements',
        'projet_souhait_usage': 'projetSouhaitUsage',
        'resume_preconisations': 'resumePreconisations',
      };
      final updates = <String, dynamic>{};
      changedFields.forEach((snake, value) {
        final camel = snakeToCamel[snake];
        if (camel != null) updates[camel] = value;
      });

      if (existing.isEmpty) {
        data
          ..['observation_equipements'] = obs.observationEquipements
          ..['projet_souhait_usage'] = obs.projetSouhaitUsage
          ..['resume_preconisations'] = obs.resumePreconisations
          ..['local_id'] = 'obs_${dossierId}_${_uuid()}';
        await txn.insert('observations_synthese', data);
      } else {
        await txn.update(
          'observations_synthese',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }

      if (updates.isEmpty) return;
      final opId = 'observations_update_$dossierId';
      await _enqueueChildUpdate(
        txn,
        operationId: opId,
        entityType: 'observations_synthese',
        dossierId: dossierId,
        updates: updates,
        baseValues: {
          for (final key in changedFields.keys)
            if (existing.isNotEmpty && snakeToCamel.containsKey(key))
              snakeToCamel[key]!: existing.first[key],
        },
        existingRow: existing.isEmpty ? null : existing.first,
        now: now,
      );
    });
    SyncEngine().notify();
  }

  Future<List<VisitRecommendationItem>> fetchVisitRecommendations(
    String dossierId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'visit_recommendations',
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );
    if (rows.isEmpty) return [];
    final itemsJson =
        jsonDecode(rows.first['items_json'] as String) as List<dynamic>;
    return itemsJson
        .map((e) => VisitRecommendationItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveVisitRecommendations(
    String dossierId,
    List<VisitRecommendationItem> items, {
    bool forceSync = false,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    await db.transaction((txn) async {
      final existing = await txn.query(
        'visit_recommendations',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      // EN LOCAL : on persiste TOUS les items (y compris ceux sans fiche
      // wiki liée) → une préconisation "vide" en cours de saisie n'est pas
      // perdue si l'app redémarre avant que l'utilisateur ait choisi
      // l'item bibliothèque.
      final itemsJson = items.map((e) => e.toJson()).toList();
      final newItemsJsonString = jsonEncode(itemsJson);

      // Optimisation 2026-05-13 : diff avec la liste existante. Si le
      // JSON sérialisé est strictement identique à ce qui est en SQLite,
      // c'est un no-op (pas de save SQLite, pas de push serveur). Cas
      // typique : `recommendations_tab._save()` se déclenche au save
      // debounce après n'importe quel rebuild même quand rien n'a
      // vraiment changé (ex. focus/blur sur un champ texte).
      if (existing.isNotEmpty) {
        final existingItemsJson = existing.first['items_json'] as String?;
        if (!forceSync && existingItemsJson == newItemsJsonString) {
          return; // rien changé → no-op total
        }
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'items_json': newItemsJsonString,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      };

      final opId = 'visitrec_update_$dossierId';
      final row = existing.isEmpty ? null : existing.first;
      final queuedPublications = await txn.query(
        'sync_operations',
        columns: const ['id'],
        where: 'id = ? AND status IN (?, ?, ?, ?)',
        whereArgs: [
          opId,
          SyncOperationStatus.pending.name,
          SyncOperationStatus.running.name,
          SyncOperationStatus.failed.name,
          'conflict',
        ],
        limit: 1,
      );
      // Keep observed linked items in the reference even if the current
      // library cache no longer contains them. Drafts were never published.
      final previousLinkedItems = row?['items_json'] == null
          ? <dynamic>[]
          : (jsonDecode(row!['items_json'] as String) as List)
                .where(
                  (item) =>
                      (item['wikiItemId'] as String? ?? '').trim().isNotEmpty,
                )
                .toList();
      final plan = planVisitRecommendationsPublication(
        items: itemsJson,
        hadPublishedItems: previousLinkedItems.isNotEmpty,
        hasPendingPublication: queuedPublications.isNotEmpty,
        remoteSnapshotExists: row?['remote_snapshot_exists'] == 1,
        remoteRevision: row?['remote_revision'] as String?,
        writeId: newSyncWriteId(),
      );
      if (existing.isEmpty) {
        data['local_id'] = 'rec_${dossierId}_${_uuid()}';
        await txn.insert('visit_recommendations', data);
      } else {
        await txn.update(
          'visit_recommendations',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }

      if (plan.shouldEnqueue) {
        // Keep the established conflict/reference payload for review screens,
        // while adding the atomic publication envelope consumed by the API.
        await _enqueueChildUpdate(
          txn,
          operationId: opId,
          entityType: 'visit_recommendations',
          dossierId: dossierId,
          updates: {'items': plan.publishedItems},
          baseValues: {
            if (row?['items_json'] != null) 'items': previousLinkedItems,
          },
          existingRow: row,
          rootFields: const ['items'],
          now: now,
        );
        final queued = await txn.query(
          'sync_operations',
          columns: const ['payload_json'],
          where: 'id = ?',
          whereArgs: [opId],
          limit: 1,
        );
        if (queued.length != 1) {
          throw StateError('Publication des préconisations introuvable');
        }
        final payload =
            jsonDecode(
                  await OfflineVault.instance.openString(
                    queued.single['payload_json'] as String,
                  ),
                )
                as Map<String, dynamic>;
        final guardValue = payload['concurrency'] ?? payload['localReference'];
        final guard = (guardValue as Map?)?.cast<String, dynamic>();
        final queuedWriteId = guard?['writeId']?.toString();
        if (queuedWriteId == null || queuedWriteId.isEmpty) {
          throw StateError('Identifiant de publication manquant');
        }
        payload['envelope'] = <String, dynamic>{
          ...plan.envelope!,
          'writeId': queuedWriteId,
        };
        await txn.update(
          'sync_operations',
          {
            'payload_json': await OfflineVault.instance.sealString(
              jsonEncode(payload),
            ),
          },
          where: 'id = ?',
          whereArgs: [opId],
        );
      } else if (row?['sync_state'] == SyncState.conflict.name) {
        await txn.update(
          'visit_recommendations',
          {'sync_state': SyncState.conflict.name},
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
    });
    SyncEngine().notify();
  }

  /// Met en file d'attente la génération du rapport PDF pour [dossierId].
  /// Utilisé par `_generateReport` côté UI quand l'ergo clique « Générer »
  /// alors qu'il est offline (ou que la requête réseau échoue) — l'op
  /// sera traitée dès le retour de connexion par
  /// `NocodbSyncService._processReportGenerationOperation`, qui appellera
  /// le serveur Express, récupèrera le PDF et l'insèrera comme document
  /// taggé « Rapport » dans l'espace Documents du dossier.
  ///
  /// Idempotent : un id `report_gen_<dossierId>` + `ConflictAlgorithm.
  /// replace` font qu'un nouveau clic sur « Générer » avant que l'ancienne
  /// op ait été drainée ne crée pas un doublon — la dernière intention
  /// gagne.
  ///
  /// Renvoie l'identifiant de la sync_op enqueued, utile pour afficher
  /// l'état dans la sidebar (« 1 rapport en attente »).
  Future<String> enqueueReportGeneration({
    required String dossierId,
    required String patientId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final opId = 'report_gen_$dossierId';
    await db.insert('sync_operations', {
      'id': opId,
      'entity_type': 'report_generation',
      'entity_local_id': dossierId,
      'operation_type': 'generate',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({'dossierId': dossierId, 'patientId': patientId}),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    SyncEngine().notify();
    return opId;
  }

  /// Pulls the remote diagnostic sanitaires payload for [dossierId] and
  /// merges it into SQLite WITHOUT enqueuing a sync operation.
  ///
  /// Skips the merge if the local row is currently in `pendingSync` —
  /// that means the user has uncommitted local edits waiting to be
  /// pushed, and we don't want to clobber them with the server copy.
  Future<bool> refreshDiagnosticSanitaireFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final remote = await api.fetchDiagnosticSanitairePayload(
      await _remoteDossierIdForRead(dossierId),
    );
    return mergeRemoteDiagnosticSanitairePayload(dossierId, remote);
  }

  Future<bool> refreshMesuresFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final remote = await api.fetchMesuresPayload(
      await _remoteDossierIdForRead(dossierId),
    );
    return mergeRemoteMesuresPayload(dossierId, remote);
  }

  Future<bool> refreshObservationsFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final remote = await api.fetchObservationsPayload(
      await _remoteDossierIdForRead(dossierId),
    );
    return mergeRemoteObservationsPayload(dossierId, remote);
  }

  Future<String> _remoteDossierIdForRead(String dossierId) async {
    final db = await _database.database;
    final rows = await db.query(
      'dossiers',
      columns: ['remote_dossier_id'],
      where: 'local_id = ?',
      whereArgs: [dossierId],
    );
    if (rows.length != 1) throw StateError('Dossier local introuvable.');
    final mapped = rows.single['remote_dossier_id']?.toString().trim();
    if ((mapped == null || mapped.isEmpty) && dossierId.startsWith('local_')) {
      throw StateError('Le dossier attend sa premiere synchronisation.');
    }
    return _remoteIdentity(mapped, dossierId);
  }

  /// Central guard used by every dossier child table.
  ///
  /// A pull must never replace an offline edit, nor a write that has just
  /// completed while NocoDB's read replica may still expose the old value.
  Future<bool> _canMergeRemoteChild({
    required DatabaseExecutor db,
    required String table,
    required String entityType,
    required String dossierId,
    bool allowPendingWithoutOperation = false,
  }) async {
    final existing = await db.query(
      table,
      columns: const ['sync_state'],
      where: 'dossier_local_id = ?',
      whereArgs: [dossierId],
      limit: 1,
    );

    final cutoff = DateTime.now()
        .subtract(const Duration(seconds: 30))
        .toIso8601String();
    final activeOrRecentOperations = await db.rawQuery(
      '''
      SELECT 1 FROM sync_operations
      WHERE entity_type = ?
        AND entity_local_id = ?
        AND (
          status IN ('pending', 'running', 'failed', 'conflict')
          OR (status = 'completed' AND updated_at > ?)
        )
      LIMIT 1
      ''',
      [entityType, dossierId, cutoff],
    );
    if (activeOrRecentOperations.isNotEmpty) return false;

    if (existing.isEmpty) return true;
    final state = existing.first['sync_state'] as String?;
    return state == null ||
        state == SyncState.synced.name ||
        (allowPendingWithoutOperation && state == SyncState.pendingSync.name);
  }

  Future<bool> mergeRemoteDiagnosticSanitairePayload(
    String dossierId,
    Map<String, dynamic>? remote,
  ) async {
    final db = await _database.database;
    return db.transaction((db) async {
      final canMerge = await _canMergeRemoteChild(
        db: db,
        table: 'diagnostic_sanitaires',
        entityType: 'diagnostic_sanitaires',
        dossierId: dossierId,
      );
      if (!canMerge) return false;

      final existing = await db.query(
        'diagnostic_sanitaires',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      if (remote == null) {
        if (existing.isEmpty) return false;
        await db.delete(
          'diagnostic_sanitaires',
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
        return true;
      }

      final sdb = (remote['sdbInstances'] as List?) ?? const [];
      final wc = (remote['wcInstances'] as List?) ?? const [];
      final now = DateTime.now().toIso8601String();
      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'sdb_instances_json': jsonEncode(sdb),
        'wc_instances_json': jsonEncode(wc),
        'remote_updated_at': _extractRemoteUpdatedAt(remote),
        'updated_at': now,
        'sync_state': SyncState.synced.name,
      };
      if (existing.isEmpty) {
        data['local_id'] = 'diag_${dossierId}_${_uuid()}';
        await db.insert('diagnostic_sanitaires', data);
      } else {
        await db.update(
          'diagnostic_sanitaires',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      return true;
    });
  }

  Future<bool> mergeRemoteMesuresPayload(
    String dossierId,
    Map<String, dynamic>? remote,
  ) async {
    final db = await _database.database;
    return db.transaction((db) async {
      final canMerge = await _canMergeRemoteChild(
        db: db,
        table: 'mesures_anthropometriques',
        entityType: 'mesures_anthropometriques',
        dossierId: dossierId,
      );
      if (!canMerge) return false;

      final existing = await db.query(
        'mesures_anthropometriques',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      if (remote == null) {
        if (existing.isEmpty) return false;
        await db.delete(
          'mesures_anthropometriques',
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
        return true;
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'debout_hauteur_coude': remote['deboutHauteurCoude'],
        'assis_hauteur_assise': remote['assisHauteurAssise'],
        'assis_profondeur_genoux': remote['assisProfondeurGenoux'],
        'assis_hauteur_coudes': remote['assisHauteurCoudes'],
        'observations': remote['observations']?.toString() ?? '',
        'remote_updated_at': _extractRemoteUpdatedAt(remote),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_state': SyncState.synced.name,
      };
      if (existing.isEmpty) {
        data['local_id'] = 'mes_remote_$dossierId';
        await db.insert('mesures_anthropometriques', data);
      } else {
        await db.update(
          'mesures_anthropometriques',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      return true;
    });
  }

  Future<bool> mergeRemoteObservationsPayload(
    String dossierId,
    Map<String, dynamic>? remote,
  ) async {
    final db = await _database.database;
    return db.transaction((db) async {
      final canMerge = await _canMergeRemoteChild(
        db: db,
        table: 'observations_synthese',
        entityType: 'observations_synthese',
        dossierId: dossierId,
      );
      if (!canMerge) return false;

      final existing = await db.query(
        'observations_synthese',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      if (remote == null) {
        if (existing.isEmpty) return false;
        await db.delete(
          'observations_synthese',
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
        return true;
      }

      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'observation_equipements':
            remote['observationEquipements']?.toString() ?? '',
        'projet_souhait_usage': remote['projetSouhaitUsage']?.toString() ?? '',
        'resume_preconisations':
            remote['resumePreconisations']?.toString() ?? '',
        'remote_updated_at': _extractRemoteUpdatedAt(remote),
        'updated_at': DateTime.now().toIso8601String(),
        'sync_state': SyncState.synced.name,
      };
      if (existing.isEmpty) {
        data['local_id'] = 'obs_remote_$dossierId';
        await db.insert('observations_synthese', data);
      } else {
        await db.update(
          'observations_synthese',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      return true;
    });
  }

  /// Pulls the remote visit recommendations for [dossierId] and merges
  /// them into SQLite WITHOUT enqueuing a sync operation. Skips if the
  /// local row is in `pendingSync` (uncommitted local edits).
  Future<bool> refreshVisitRecommendationsFromRemote(String dossierId) async {
    final NocodbApiClient api = NocodbApiClient();
    final snapshot = await api.fetchVisitRecommendationsSnapshot(dossierId);
    return mergeRemoteVisitRecommendationsPayload(
      dossierId,
      (snapshot['items'] as List).cast<Map<String, dynamic>>(),
      remoteRevision: snapshot['revision']?.toString(),
      remoteSnapshotExists: snapshot['snapshotExists'] == true,
    );
  }

  /// Resolve a publication revision conflict using the edit times of the
  /// local list and the server snapshot. The local drafts stay local when the
  /// server version wins.
  Future<bool> resolveVisitRecommendationsByLatestEdit(
    String dossierId,
    Map<String, dynamic> snapshot,
  ) async {
    final remoteAt = DateTime.tryParse(snapshot['updatedAt']?.toString() ?? '');
    final remoteRevision = snapshot['revision']?.toString();
    final remoteItems = (snapshot['items'] as List?)
        ?.whereType<Map>()
        .map((item) => item.cast<String, dynamic>())
        .toList();
    if (remoteAt == null ||
        remoteItems == null ||
        remoteRevision == null ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          caseSensitive: false,
        ).hasMatch(remoteRevision)) {
      return false;
    }
    final db = await _database.database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'visit_recommendations',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );
      final operations = await txn.query(
        'sync_operations',
        where:
            "entity_type = 'visit_recommendations' AND entity_local_id = ? AND status = 'conflict'",
        whereArgs: [dossierId],
        limit: 2,
      );
      if (rows.length != 1 || operations.length != 1) return false;
      final localAt = DateTime.tryParse(
        rows.single['updated_at']?.toString() ?? '',
      );
      if (localAt == null || localAt.isAtSameMomentAs(remoteAt)) return false;
      final op = operations.single;
      final now = DateTime.now().toIso8601String();
      if (localAt.isAfter(remoteAt)) {
        final payload =
            jsonDecode(
                  await OfflineVault.instance.openString(
                    op['payload_json'] as String,
                  ),
                )
                as Map<String, dynamic>;
        final envelope = (payload['envelope'] as Map?)?.cast<String, dynamic>();
        if (envelope == null || envelope['items'] is! List) return false;
        final writeId = newSyncWriteId();
        payload
          ..remove('conflict')
          ..['envelope'] = {
            ...envelope,
            'writeId': writeId,
            'expectedRevision': remoteRevision,
          };
        await txn.update(
          'sync_operations',
          {
            'payload_json': await OfflineVault.instance.sealString(
              jsonEncode(payload),
            ),
            'status': 'pending',
            'attempt_count': 0,
            'last_error': null,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [op['id']],
        );
        await txn.update(
          'visit_recommendations',
          {
            'remote_revision': remoteRevision,
            'remote_snapshot_exists': 1,
            'sync_state': SyncState.pendingSync.name,
          },
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      } else {
        final localItems =
            (jsonDecode(rows.single['items_json'] as String) as List)
                .whereType<Map>()
                .map((item) => item.cast<String, dynamic>())
                .toList();
        final merged = mergePublishedRecommendationsWithLocalDrafts(
          remotePublishedItems: remoteItems,
          localItems: localItems,
        );
        await txn.update(
          'sync_operations',
          {'status': 'completed', 'last_error': null, 'updated_at': now},
          where: 'id = ?',
          whereArgs: [op['id']],
        );
        await txn.update(
          'visit_recommendations',
          {
            'items_json': jsonEncode(merged),
            'remote_revision': remoteRevision,
            'remote_snapshot_exists': 1,
            'sync_state':
                merged.any(
                  (item) => (item['wikiItemId']?.toString() ?? '').isEmpty,
                )
                ? SyncState.pendingSync.name
                : SyncState.synced.name,
            'updated_at': snapshot['updatedAt'],
          },
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      return true;
    });
  }

  Future<bool> mergeRemoteVisitRecommendationsPayload(
    String dossierId,
    List<Map<String, dynamic>> remoteItems, {
    String? remoteRevision,
    bool remoteSnapshotExists = false,
  }) async {
    final db = await _database.database;
    return db.transaction((db) async {
      final canMerge = await _canMergeRemoteChild(
        db: db,
        table: 'visit_recommendations',
        entityType: 'visit_recommendations',
        dossierId: dossierId,
        // A draft without wikiItemId intentionally has no sync operation.
        // It can coexist with the remote list and must not freeze the pull.
        allowPendingWithoutOperation: true,
      );
      if (!canMerge) return false;

      final existing = await db.query(
        'visit_recommendations',
        where: 'dossier_local_id = ?',
        whereArgs: [dossierId],
        limit: 1,
      );

      // MERGE remote + drafts locaux (items sans wikiItemId, non pushés car
      // le serveur les refuse). Sans ce merge, un draft en cours de saisie
      // serait perdu au prochain refresh après le push des items complets.
      final List<Map<String, dynamic>> localDrafts = [];
      if (existing.isNotEmpty) {
        final raw = existing.first['items_json'] as String? ?? '[]';
        try {
          final decoded = (jsonDecode(raw) as List)
              .cast<Map<String, dynamic>>();
          for (final item in decoded) {
            final wikiId = (item['wikiItemId'] as String?) ?? '';
            if (wikiId.trim().isEmpty) localDrafts.add(item);
          }
        } catch (_) {}
      }
      final merged = [...remoteItems, ...localDrafts];

      final now = DateTime.now().toIso8601String();
      final data = <String, dynamic>{
        'dossier_local_id': dossierId,
        'items_json': jsonEncode(merged),
        'remote_revision': remoteRevision,
        'remote_snapshot_exists': remoteSnapshotExists ? 1 : 0,
        'updated_at': now,
        // Si on a des drafts, on garde pendingSync pour que le prochain
        // refresh ne tente pas de les écraser. Sinon synced.
        'sync_state': localDrafts.isEmpty
            ? SyncState.synced.name
            : SyncState.pendingSync.name,
      };
      if (existing.isEmpty) {
        data['local_id'] = 'rec_${dossierId}_${_uuid()}';
        await db.insert('visit_recommendations', data);
      } else {
        await db.update(
          'visit_recommendations',
          data,
          where: 'dossier_local_id = ?',
          whereArgs: [dossierId],
        );
      }
      return true;
    });
  }
}
