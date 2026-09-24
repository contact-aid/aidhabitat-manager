import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/types.dart';
import 'document_content_url.dart';
import 'document_file_naming.dart';
import 'document_revision_store.dart';
import 'document_upload_identity.dart';
import 'local_database.dart';
import 'media_cache_service.dart';
import 'native_file_protection.dart';
import 'offline_vault.dart';
import 'pdf_ink_geometry.dart';
import 'document_storage_path.dart';
import 'sync_engine.dart';

@visibleForTesting
String resolveReplacementDocumentPath({
  required String applicationDocumentsPath,
  required String? existingPath,
  required String patientId,
  required String documentId,
  required String fileName,
  required String mimeType,
}) {
  final documentsRoot = p.normalize(p.absolute(applicationDocumentsPath));
  final extension = _replacementExtension(fileName, mimeType);
  final normalizedExisting = existingPath == null || existingPath.trim().isEmpty
      ? null
      : p.normalize(p.absolute(existingPath.trim()));

  // Les UUID de sandbox iOS changent notamment après une réinstallation ou
  // une mise à jour TestFlight. Un ancien chemin ne doit jamais être réutilisé,
  // pas plus que la racine du conteneur visible dans le bug BOISSIN Chantal.
  if (normalizedExisting != null &&
      p.isWithin(documentsRoot, normalizedExisting) &&
      p.extension(normalizedExisting).toLowerCase() == extension) {
    return normalizedExisting;
  }

  final safePatientId = _safeStorageSegment(patientId, fallback: 'patient');
  final safeDocumentId = _safeStorageSegment(documentId, fallback: 'document');
  return p.join(
    documentsRoot,
    'offline_documents',
    safePatientId,
    '$safeDocumentId$extension',
  );
}

String _replacementExtension(String fileName, String mimeType) {
  final fromName = p.extension(p.basename(fileName)).toLowerCase();
  if (fromName.isNotEmpty && RegExp(r'^\.[a-z0-9]{1,10}$').hasMatch(fromName)) {
    return fromName;
  }
  if (mimeType == 'application/pdf') return '.pdf';
  if (mimeType == 'image/jpeg') return '.jpg';
  if (mimeType == 'image/png') return '.png';
  return '.bin';
}

String _safeStorageSegment(String value, {required String fallback}) {
  final safe = value
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
      .replaceAll(RegExp(r'^\.+|\.+$'), '');
  return safe.isEmpty ? fallback : safe;
}

class DocumentRepositoryChange {
  const DocumentRepositoryChange({
    required this.patientId,
    this.dossierId,
    this.documentId,
    required this.reason,
  });

  final String patientId;
  final String? dossierId;
  final String? documentId;
  final String reason;
}

class DocumentRepository {
  DocumentRepository({
    LocalDatabase? database,
    DocumentRevisionStore? revisionStore,
    Future<File?> Function(String url)? remoteFileFetcher,
    this.prefetchRemoteAssets = true,
  }) : _database = database ?? LocalDatabase.instance,
       _revisionStore = revisionStore ?? DocumentRevisionStore(),
       _remoteFileFetcher = remoteFileFetcher;

  static final StreamController<DocumentRepositoryChange> _changesController =
      StreamController<DocumentRepositoryChange>.broadcast();

  static Stream<DocumentRepositoryChange> get changes =>
      _changesController.stream;

  final LocalDatabase _database;
  final DocumentRevisionStore _revisionStore;
  final Future<File?> Function(String url)? _remoteFileFetcher;
  final bool prefetchRemoteAssets;

  Future<DocItem?> fetchDocument(String documentId) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'local_id = ? AND pending_delete = 0',
      whereArgs: [documentId],
      limit: 1,
    );
    return rows.isEmpty ? null : _mapRow(rows.single);
  }

  void _notifyChanged({
    required String patientId,
    String? dossierId,
    String? documentId,
    required String reason,
  }) {
    _changesController.add(
      DocumentRepositoryChange(
        patientId: patientId,
        dossierId: dossierId,
        documentId: documentId,
        reason: reason,
      ),
    );
  }

  Future<List<DocItem>> fetchDocuments(String patientId) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'patient_local_id = ? AND pending_delete = 0',
      whereArgs: [patientId],
      orderBy: 'updated_at DESC, created_at DESC',
    );

    final out = <DocItem>[];
    for (final row in rows) {
      out.add(await _mapRow(row));
    }
    return out;
  }

  /// Charge les bytes locaux des documents VAD (tags `Visite - …`) pour
  /// un patient, en vue de les embarquer **inline** dans la requête de
  /// génération PDF. Permet au serveur de générer le rapport même si la
  /// sync NocoDB est en retard ou a échoué partiellement (cf. edge case
  /// "réseau intermittent" : 8 photos prises offline, certaines sont
  /// montées avant la coupure, d'autres pas — sans inline, le PDF
  /// arrive incomplet ou la génération est différée).
  ///
  /// Filtre :
  ///   - tag matche un préfixe `Visite - ` (logement / acces / sani)
  ///   - `pending_delete = 0`
  ///   - bytes disponibles localement (`local_file_data_url` web ou
  ///     `local_file_path` natif)
  ///   - bytes disponibles localement (`local_file_data_url` web ou
  ///     `local_file_path` natif), même si le document est déjà syncé :
  ///     l'ordre `category_order` est local et doit être envoyé au
  ///     générateur PDF immédiatement après un drag/reorder.
  ///
  /// Renvoie une liste de `InlineDocumentBytes`, prête à être convertie
  /// en `MultipartFile` par [NocodbApiClient.downloadVisitReport].
  Future<List<InlineDocumentBytes>> fetchVisitReportInlineBytes(
    String patientId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where:
          'patient_local_id = ? AND pending_delete = 0 '
          "AND mime_type LIKE 'image/%' "
          "AND tags_json LIKE '%Visite - %'",
      whereArgs: [patientId],
      orderBy:
          'category_order IS NULL ASC, category_order ASC, created_at DESC',
    );

    final result = <InlineDocumentBytes>[];
    for (final row in rows) {
      final tagsRaw = row['tags_json'] as String? ?? '[]';
      final tags = (jsonDecode(tagsRaw) as List<dynamic>).cast<String>();
      // Double-filtre côté Dart (le LIKE SQL ci-dessus est approximatif).
      final hasVisitTag = tags.any((t) => t.startsWith('Visite - '));
      if (!hasVisitTag) continue;

      Uint8List? bytes;

      // 1) Web/PWA : bytes encodés en base64 dans `local_file_data_url`.
      final dataUrl = await OfflineVault.instance.openNullableString(
        row['local_file_data_url'] as String?,
      );
      if (dataUrl != null && dataUrl.isNotEmpty) {
        final match = RegExp(r'^data:[^;]+;base64,(.+)$').firstMatch(dataUrl);
        if (match != null) {
          try {
            bytes = base64Decode(match.group(1)!);
          } catch (_) {
            // dataUrl corrompu : on tente la fallback file path.
          }
        }
      }

      // 2) Natif : fichier copié dans le sandbox app via `local_file_path`.
      if (bytes == null && !kIsWeb) {
        final filePath = row['local_file_path'] as String?;
        if (filePath != null && filePath.isNotEmpty) {
          try {
            final file = File(filePath);
            if (await file.exists()) {
              await NativeFileProtection.instance.protectPath(file.path);
              bytes = await file.readAsBytes();
            }
          } catch (_) {
            // I/O error : on skip ce doc, le serveur retombera sur NocoDB.
          }
        }
      }

      if (bytes == null || bytes.isEmpty) continue;

      result.add(
        InlineDocumentBytes(
          localId: row['local_id'] as String,
          fileName: publicDocumentFileName(
            storedName: row['file_name'] as String? ?? '',
            title: row['title'] as String? ?? '',
            mimeType: row['mime_type'] as String?,
          ),
          mimeType: row['mime_type'] as String,
          tags: tags,
          title: row['title'] as String? ?? '',
          categoryOrder: (row['category_order'] as num?)?.toInt(),
          dossierId: row['dossier_local_id'] as String?,
          bytes: bytes,
        ),
      );
    }
    return result;
  }

  /// Ordre local des photos VAD, même quand les bytes ne sont plus
  /// disponibles en local. Le PDF serveur peut ainsi trier les photos
  /// déjà présentes dans NocoDB selon le dernier drag/reorder de l'app.
  Future<List<InlineDocumentOrder>> fetchVisitReportPhotoOrder(
    String patientId,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: [
        'local_id',
        'category_order',
        'tags_json',
        'remote_file_path',
        'remote_public_url',
      ],
      where:
          'patient_local_id = ? AND pending_delete = 0 '
          "AND mime_type LIKE 'image/%' "
          "AND tags_json LIKE '%Visite - %' "
          'AND category_order IS NOT NULL',
      whereArgs: [patientId],
      orderBy: 'category_order ASC, created_at DESC',
    );

    final result = <InlineDocumentOrder>[];
    for (final row in rows) {
      final tagsRaw = row['tags_json'] as String? ?? '[]';
      final tags = (jsonDecode(tagsRaw) as List<dynamic>).cast<String>();
      if (!tags.any((t) => t.startsWith('Visite - '))) continue;
      final order = (row['category_order'] as num?)?.toInt();
      if (order == null) continue;
      final localId = row['local_id'] as String;
      final ids = <String>{localId, _extractRemoteIdFromRow(row, localId)}
        ..removeWhere((id) => id.trim().isEmpty);
      for (final id in ids) {
        result.add(InlineDocumentOrder(localId: id, categoryOrder: order));
      }
    }
    return result;
  }

  /// Web-friendly import that takes bytes + metadata directly (no
  /// [File]) since PWAs don't have a filesystem. The bytes are stored as
  /// a `data:<mime>;base64,…` URL in `documents.local_file_data_url` and
  /// the sync processor decodes them when pushing to NocoDB.
  /// Insert un document SANS queuer d'upload — pour le cas où le
  /// serveur a déjà sauvegardé le PDF en NocoDB (cf. génération de
  /// rapport, demande utilisateur 2026-04-29). Le doc local est
  /// directement marqué `synced` avec son `remote_file_path` pointant
  /// sur l'UUID NocoDB, donc le polling `mergeRemoteDocuments` le
  /// reconnaît au prochain refresh sans créer de doublon.
  ///
  /// Évite la boucle 413 Content Too Large quand le PDF dépasse la
  /// limite ~4.5 MB de Vercel Hobby.
  Future<DocItem> importDocumentRemoteOnly({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    required String remoteUuid,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,

    /// Identifiant déterministe assigné par le client (Flutter) — DOIT
    /// correspondre au `client_document_id` que le serveur a stocké
    /// dans NocoDB. Utilisé comme `local_id` pour que `mergeRemoteDocuments`
    /// puisse retrouver cette ligne au prochain polling et éviter de
    /// créer un doublon.
    ///
    /// Si null → fallback sur `remoteUuid` (comportement legacy, à
    /// éviter pour les rapports : crée un doublon au prochain pull
    /// car le serveur renvoie `clientDocumentId = doc_report_<dossierId>`
    /// qui ne matche aucun `local_id` existant). Bug reporté
    /// 2026-05-05.
    String? clientDocumentId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(fileName);
    // Priorité au clientDocumentId pour que le merge polling matche
    // par `local_id == clientDocumentId`. Fallback sur remoteUuid si
    // l'appelant ne le connaît pas (cas legacy).
    final localId = (clientDocumentId != null && clientDocumentId.isNotEmpty)
        ? clientDocumentId
        : remoteUuid;
    final mimeType = _mimeTypeFor(extension);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final dataUrlAtRest = await OfflineVault.instance.sealString(dataUrl);

    // Native (macOS/iOS/iPad) : on persiste les bytes sur disque pour
    // que le PDF annotator puisse les ouvrir. Sans ça, `localPath`
    // restait null → la condition de preview au l.3482 du
    // documents_screen tombait sur `_unsupportedPanel` (« Prévisualisation
    // non disponible pour ce format ») — bug reporté 2026-04-30 sur
    // les rapports générés.
    //
    // Web : pas de fichier (path_provider indispo), on garde
    // uniquement le data URL.
    String? localFilePath;
    if (!kIsWeb) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final docsDirPath = p.join(appDir.path, 'offline_documents', patientId);
        await NativeFileProtection.instance.ensureProtectedDirectory(
          docsDirPath,
          recursive: true,
        );
        final docsDir = Directory(
          p.join(appDir.path, 'offline_documents', patientId),
        );
        // Nom déterministe basé sur le remoteUuid → idempotent : un
        // 2ème appel pour le même rapport overwrite le fichier sans
        // créer de doublon. Préserve l'extension d'origine pour
        // qu'`OpenFilex.open` ouvre dans la bonne app native.
        final storedPath = p.join(docsDir.path, '$remoteUuid.$extension');
        await NativeFileProtection.instance.writeProtectedBytes(
          storedPath,
          bytes,
        );
        localFilePath = storedPath;
      } catch (_) {
        // Si la persistance disque échoue (permissions, disque plein),
        // on retombe sur le data URL — la preview ne marchera pas mais
        // le doc reste utilisable (download via "Ouvrir dans une autre
        // app", upload, etc).
        localFilePath = null;
      }
    }

    final row = {
      'local_id': localId,
      'patient_local_id': patientId,
      'dossier_local_id': dossierId,
      'title': resolvedTitle,
      'file_name': fileName,
      'file_ext': extension,
      'mime_type': mimeType,
      'local_file_path': localFilePath,
      // Bytes en local pour vignette immédiate, sans avoir à pull
      // depuis NocoDB le binaire (qui passerait par /api/mobile-documents/.../content).
      'local_file_data_url': dataUrlAtRest,
      // remote_file_path = UUID NocoDB → permet à mergeRemoteDocuments
      // de matcher au prochain pull sans dupliquer.
      'remote_file_path': remoteUuid,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'category_order': categoryOrder,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.synced.name,
      'pending_delete': 0,
    };

    await db.insert(
      'documents',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    // PAS de sync_operations — le doc est déjà côté serveur.
    _notifyChanged(
      patientId: patientId,
      dossierId: dossierId,
      documentId: localId,
      reason: 'import_remote_only',
    );
    return await _mapRow(row);
  }

  Future<DocItem> importDocumentBytes({
    required String patientId,
    required List<int> bytes,
    required String fileName,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
    String? dossierId,

    /// Optionnel : id déterministe pour permettre la dédup. Quand
    /// fourni et qu'une ligne existe déjà, on REPLACE (ConflictAlgorithm.
    /// replace). Cas d'usage : le rapport PDF d'un dossier (« Rapport »
    /// tag) qui doit toujours être 1 doc unique par dossier — sans ça,
    /// chaque retry de la sync_op `report_generation` créait un nouveau
    /// doc avec un id timestamp, finissant par 15 copies dans NocoDB
    /// (bug reporté 2026-04-30). Quand non fourni (cas normal), on
    /// génère un id timestamp pour un nouveau doc.
    String? localId,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p.extension(fileName).replaceFirst('.', '').toLowerCase();
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(fileName);
    final resolvedLocalId = localId ?? 'doc_${now.microsecondsSinceEpoch}';
    final mimeType = _mimeTypeFor(extension);
    final dataUrl = 'data:$mimeType;base64,${base64Encode(bytes)}';
    final dataUrlAtRest = await OfflineVault.instance.sealString(dataUrl);

    // Native : persiste les bytes sur disque pour que le PDF annotator
    // puisse les ouvrir (cf. importDocumentRemoteOnly pour le rationale
    // détaillé — bug « Prévisualisation non disponible » 2026-04-30).
    String? localFilePath;
    if (!kIsWeb) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final docsDirPath = p.join(appDir.path, 'offline_documents', patientId);
        await NativeFileProtection.instance.ensureProtectedDirectory(
          docsDirPath,
          recursive: true,
        );
        final docsDir = Directory(
          p.join(appDir.path, 'offline_documents', patientId),
        );
        final storedPath = p.join(docsDir.path, '$resolvedLocalId.$extension');
        await NativeFileProtection.instance.writeProtectedBytes(
          storedPath,
          bytes,
        );
        localFilePath = storedPath;
      } catch (_) {
        localFilePath = null;
      }
    }

    // Si on REPLACE un doc déterministe (ex. le rapport PDF), on
    // préserve les éventuelles annotations existantes (l'ergo a peut-
    // être dessiné/écrit sur l'ancien rapport — re-générer ne doit
    // pas wiper son travail).
    Map<String, Object?>? preservedFields;
    if (localId != null) {
      final existing = await db.query(
        'documents',
        columns: ['annotations_json', 'created_at'],
        where: 'local_id = ?',
        whereArgs: [resolvedLocalId],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        preservedFields = {
          'annotations_json': existing.first['annotations_json'],
          // Les rapports doivent afficher la date de dernière
          // génération. Les autres documents déterministes gardent leur
          // date de création initiale.
          if (!tags.any((tag) => tag.trim().toLowerCase() == 'rapport'))
            'created_at': existing.first['created_at'],
        };
      }
    }

    final row = {
      'local_id': resolvedLocalId,
      'patient_local_id': patientId,
      // Optionnel mais conseillé : permet le scoping par dossier dans
      // les futures requêtes (ex. liste docs d'une visite spécifique).
      // Le filtre Documents primaire reste `patient_local_id`.
      'dossier_local_id': dossierId,
      'title': resolvedTitle,
      'file_name': fileName,
      'file_ext': extension,
      'mime_type': mimeType,
      'local_file_path': localFilePath,
      'local_file_data_url': dataUrlAtRest,
      'remote_file_path': null,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'category_order': categoryOrder,
      'created_at': preservedFields?['created_at'] ?? now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.pendingSync.name,
      'pending_delete': 0,
      if (preservedFields?['annotations_json'] != null)
        'annotations_json': preservedFields!['annotations_json'],
    };

    // ConflictAlgorithm.replace pour le path déterministe (regénération
    // de rapport) ; insert simple sinon (nouveau doc).
    await db.insert(
      'documents',
      row,
      conflictAlgorithm: localId != null
          ? ConflictAlgorithm.replace
          : ConflictAlgorithm.abort,
    );
    await db.insert(
      'sync_operations',
      {
        'id': 'sync_$resolvedLocalId',
        'entity_type': 'document',
        'entity_local_id': resolvedLocalId,
        'operation_type': 'upload_file',
        'payload_json': await OfflineVault.instance.sealString(
          jsonEncode({
            'patientLocalId': patientId,
            // IMPORTANT : on envoie `resolvedLocalId` (et pas `localId`)
            // pour que le serveur dedupe correctement via
            // `client_document_id`. Sans ça, un retry de regénération
            // de rapport créait une 2e ligne NocoDB malgré le replace
            // local — bug reporté 2026-04-30 (« 15 documents dans le
            // dossier alors que j'en vois seulement un »).
            'documentLocalId': resolvedLocalId,
            'dataUrl': dataUrl,
            'title': resolvedTitle,
            'fileName': fileName,
            'mimeType': mimeType,
            'tags': tags,
          }),
        ),
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      },
      // Replace si on retry une regénération avec le même localId
      // (sinon UNIQUE constraint sur 'id'='sync_<localId>' fait
      // échouer le 2ème appel).
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    SyncEngine().notify();
    _notifyChanged(
      patientId: patientId,
      dossierId: dossierId,
      documentId: resolvedLocalId,
      reason: 'import_bytes',
    );
    return await _mapRow(row);
  }

  Future<DocItem> importDocument({
    required String patientId,
    required File sourceFile,
    List<String> tags = const ['Autre'],
    String? title,
    int? categoryOrder,
  }) async {
    final db = await _database.database;
    final now = DateTime.now();
    final extension = p
        .extension(sourceFile.path)
        .replaceFirst('.', '')
        .toLowerCase();
    final baseName = p.basename(sourceFile.path);
    final resolvedTitle = (title != null && title.trim().isNotEmpty)
        ? title.trim()
        : p.basenameWithoutExtension(sourceFile.path);
    final localId = 'doc_${now.microsecondsSinceEpoch}';
    final appDir = await getApplicationDocumentsDirectory();
    final docsDirPath = p.join(appDir.path, 'offline_documents', patientId);
    await NativeFileProtection.instance.ensureProtectedDirectory(
      docsDirPath,
      recursive: true,
    );
    final docsDir = Directory(docsDirPath);
    final storedPath = p.join(
      docsDir.path,
      '${now.millisecondsSinceEpoch}_$baseName',
    );
    await NativeFileProtection.instance.copyProtectedFile(
      sourceFile,
      storedPath,
    );

    final row = {
      'local_id': localId,
      'patient_local_id': patientId,
      'title': resolvedTitle,
      'file_name': baseName,
      'file_ext': extension,
      'mime_type': _mimeTypeFor(extension),
      'local_file_path': storedPath,
      'remote_file_path': null,
      'remote_public_url': null,
      'tags_json': jsonEncode(tags),
      'category_order': categoryOrder,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
      'sync_state': SyncState.pendingSync.name,
      'pending_delete': 0,
    };

    await db.insert('documents', row);
    await db.insert('sync_operations', {
      'id': 'sync_$localId',
      'entity_type': 'document',
      'entity_local_id': localId,
      'operation_type': 'upload_file',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({
          'patientLocalId': patientId,
          'documentLocalId': localId,
          'localPath': storedPath,
          'title': resolvedTitle,
          'fileName': baseName,
          'mimeType': row['mime_type'],
          'tags': tags,
        }),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });

    SyncEngine().notify();
    _notifyChanged(
      patientId: patientId,
      documentId: localId,
      reason: 'import_file',
    );

    return await _mapRow(row);
  }

  /// Variante **web** : prend les bytes flattened directement (pas de
  /// filesystem dans le navigateur). Encode en data URL et enqueue une
  /// op d'upload qui sera ré-hydratée par `_processDocumentOperation`
  /// via le champ `dataUrl` du payload. Le `documentLocalId` reste le
  /// même, donc côté NocoDB on remplace l'asset existant (parité avec
  /// la variante natif `enqueueAnnotatedReupload`).
  /// Enregistre l'aplat (PDF page + traits ergo) d'UNE SEULE PAGE
  /// d'un PDF dans la map `annotations_json` du document, sans
  /// toucher au PDF original. Le PDF reste navigable, et la preview
  /// affiche l'aplat PNG sur les pages qui ont une entrée dans la map.
  ///
  /// Format du JSON stocké : `{"1": "data:image/png;base64,...", "3": "..."}`
  /// (clé = numéro de page 1-indexé, valeur = data URL PNG).
  ///
  /// Symptôme avant ce mécanisme :
  /// `enqueueAnnotatedReuploadBytes` remplaçait le PDF entier par le
  /// PNG d'une seule page → perte des autres pages, plus de
  /// navigation, le `file_ext` passait à 'png' et la preview ne savait
  /// plus distinguer un vrai PDF d'un image annotée.
  ///
  /// Cette méthode est utilisée pour les annotations PDF par page.
  /// Les annotations sur images "simples" (jpg/png originaux)
  /// continuent d'utiliser `enqueueAnnotatedReuploadBytes` qui flatten
  /// directement le fichier source (puisqu'il n'y a qu'une "page").
  ///
  /// Note : le sync NocoDB n'est pas câblé pour les overlays par page
  /// en v1 — les annotations restent local-only. Voir TODO dans le
  /// sync engine pour pousser une op `update_annotations`.
  Future<void> enqueueAnnotatedPageBytes({
    required String documentId,
    required int pageNumber,
    required Uint8List bytes,
  }) async {
    if (pageNumber < 1) return;
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: ['patient_local_id', 'dossier_local_id', 'annotations_json'],
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    // Lit la map existante, ajoute/écrase l'entrée de la page courante.
    final existingJson = await OfflineVault.instance.openString(
      rows.first['annotations_json'] as String? ?? '',
    );
    Map<String, dynamic> map = {};
    if (existingJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(existingJson);
        if (decoded is Map<String, dynamic>) map = decoded;
      } catch (_) {
        // JSON corrompu → on repart d'une map vide. La page de l'ergo
        // sera la 1re entrée. Les anciennes annotations sont perdues
        // mais c'était déjà cassé.
      }
    }
    final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
    map['$pageNumber'] = dataUrl;

    final now = DateTime.now().toIso8601String();
    await db.update(
      'documents',
      {
        'annotations_json': await OfflineVault.instance.sealString(
          jsonEncode(map),
        ),
        'updated_at': now,
        // Pas de `sync_state = pendingSync` — les annotations restent
        // local-only en v1, pas de push NocoDB. Le doc PDF original
        // garde son sync_state existant (synced typiquement).
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    _notifyChanged(
      patientId: rows.first['patient_local_id'] as String? ?? '',
      dossierId: rows.first['dossier_local_id'] as String?,
      documentId: documentId,
      reason: 'annotate_page',
    );
  }

  /// Copie les annotations locales lors d'une duplication de document.
  /// Le fichier source reste inchangé et les overlays PDF demeurent associés
  /// au nouveau document, aussi bien sur web (`annotations_json`) que sur
  /// natif (sidecars JSON par page).
  Future<void> copyDocumentAnnotations({
    required String sourceDocumentId,
    required String targetDocumentId,
  }) async {
    if (sourceDocumentId == targetDocumentId) return;
    final db = await _database.database;
    final sourceRows = await db.query(
      'documents',
      columns: ['annotations_json', 'local_file_path'],
      where: 'local_id = ?',
      whereArgs: [sourceDocumentId],
      limit: 1,
    );
    final targetRows = await db.query(
      'documents',
      columns: ['local_file_path'],
      where: 'local_id = ?',
      whereArgs: [targetDocumentId],
      limit: 1,
    );
    if (sourceRows.isEmpty || targetRows.isEmpty) return;

    final sourceAnnotations = await OfflineVault.instance.openString(
      sourceRows.first['annotations_json'] as String? ?? '',
    );
    if (sourceAnnotations.isNotEmpty) {
      await db.update(
        'documents',
        {
          'annotations_json': await OfflineVault.instance.sealString(
            sourceAnnotations,
          ),
        },
        where: 'local_id = ?',
        whereArgs: [targetDocumentId],
      );
    }

    if (kIsWeb) return;
    final sourcePath =
        (sourceRows.first['local_file_path'] as String?)?.trim() ?? '';
    final targetPath =
        (targetRows.first['local_file_path'] as String?)?.trim() ?? '';
    if (sourcePath.isEmpty || targetPath.isEmpty) return;

    final directory = File(sourcePath).parent;
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.startsWith('$sourcePath.page') ||
          !entity.path.endsWith('.png.annotation.json')) {
        continue;
      }
      final targetSidecar =
          '$targetPath${entity.path.substring(sourcePath.length)}';
      await NativeFileProtection.instance.copyProtectedFile(
        entity,
        targetSidecar,
      );
    }
  }

  Future<DocItem> enqueueAnnotatedReuploadBytes({
    required String documentId,
    required Uint8List bytes,
    DocItem? expectedDocument,
  }) => _replaceDocumentContent(
    documentId: documentId,
    bytes: bytes,
    mimeType: 'image/png',
    annotated: true,
    expectedDocument: expectedDocument,
  );

  /// Publish a new local revision and its upload intent in one transaction.
  Future<DocItem> enqueueReplacementBytes({
    required String documentId,
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    String? annotationSourcePath,
    bool preservePdfSidecars = true,
    DocItem? expectedDocument,
  }) => _replaceDocumentContent(
    documentId: documentId,
    bytes: bytes,
    fileName: fileName,
    mimeType: mimeType,
    annotationSourcePath: annotationSourcePath,
    preservePdfSidecars: preservePdfSidecars,
    expectedDocument: expectedDocument,
  );

  Future<DocItem> enqueueReplacementFile({
    required String documentId,
    required File sourceFile,
    required String fileName,
    required String mimeType,
    String? annotationSourcePath,
    bool preservePdfSidecars = true,
    DocItem? expectedDocument,
  }) => _replaceDocumentContent(
    documentId: documentId,
    sourceFile: sourceFile,
    fileName: fileName,
    mimeType: mimeType,
    annotationSourcePath: annotationSourcePath,
    preservePdfSidecars: preservePdfSidecars,
    expectedDocument: expectedDocument,
  );

  Future<void> enqueueAnnotatedReupload({
    required String documentId,
    required String flattenedPath,
  }) => _replaceDocumentContent(
    documentId: documentId,
    sourceFile: File(flattenedPath),
    mimeType: 'image/png',
    annotated: true,
  );

  Future<DocItem> _replaceDocumentContent({
    required String documentId,
    required String mimeType,
    Uint8List? bytes,
    File? sourceFile,
    String? fileName,
    bool annotated = false,
    String? annotationSourcePath,
    bool preservePdfSidecars = true,
    DocItem? expectedDocument,
  }) async {
    if (bytes != null && bytes.isEmpty) {
      throw const FileSystemException('Le document produit est vide');
    }
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      where: 'local_id = ? AND pending_delete = 0',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Document absent ou supprime : sauvegarde impossible');
    }
    final snapshot = rows.single;
    if (expectedDocument != null &&
        !samePdfEditingRevision(expectedDocument, await _mapRow(snapshot))) {
      throw StateError(
        'Le document a change pendant la preparation. Rouvrez-le.',
      );
    }
    if (expectedDocument != null &&
        !preservePdfSidecars &&
        await OfflineVault.instance.openNullableString(
              snapshot['annotations_json'] as String?,
            ) !=
            expectedDocument.annotationsJson) {
      throw StateError('Les annotations ont change pendant la preparation.');
    }
    final originalName = snapshot['file_name'] as String? ?? 'document.bin';
    final publicFileName = publicDocumentFileName(
      storedName: annotated
          ? '${p.basenameWithoutExtension(originalName)}-annoté.png'
          : fileName!,
      title: snapshot['title'] as String? ?? 'Document',
      mimeType: mimeType,
    );
    final extension = documentFileExtension(
      storedName: publicFileName,
      mimeType: mimeType,
    ).replaceFirst('.', '').toLowerCase();
    final dataUrl = kIsWeb
        ? 'data:$mimeType;base64,${base64Encode(bytes!)}'
        : null;
    final sealedDataUrl = await OfflineVault.instance.sealNullableString(
      dataUrl,
    );
    final revision = kIsWeb
        ? null
        : await _revisionStore.prepare(
            extension: extension,
            bytes: bytes,
            sourceFile: sourceFile,
            annotationSourcePath:
                mimeType == 'application/pdf' && preservePdfSidecars
                ? annotationSourcePath ??
                      await resolveDocumentStoragePath(
                        snapshot['local_file_path'] as String? ?? '',
                      )
                : null,
          );
    final random = Random.secure();
    final operationId =
        'sync_replace_${base64UrlEncode(List<int>.generate(24, (_) => random.nextInt(256)))}';

    // A crash before commit leaves only an unreferenced revision. A crash
    // after commit leaves both the complete file and a durable pending upload.
    // Retain old files: an in-flight upload or open viewer may still need them.
    late Map<String, Object?> committedRow;
    await db.transaction((txn) async {
      final currentRows = await txn.query(
        'documents',
        where: 'local_id = ? AND pending_delete = 0',
        whereArgs: [documentId],
        limit: 1,
      );
      if (currentRows.isEmpty) {
        throw StateError('Document supprime pendant la sauvegarde');
      }
      final current = currentRows.single;
      if (current['local_file_path'] != snapshot['local_file_path'] ||
          current['local_file_data_url'] != snapshot['local_file_data_url'] ||
          current['patient_local_id'] != snapshot['patient_local_id'] ||
          ((snapshot['local_file_path'] as String? ?? '').isEmpty &&
              (snapshot['local_file_data_url'] as String? ?? '').isEmpty &&
              (current['remote_file_path'] != snapshot['remote_file_path'] ||
                  current['remote_public_url'] !=
                      snapshot['remote_public_url'])) ||
          (!preservePdfSidecars &&
              current['annotations_json'] != snapshot['annotations_json'])) {
        throw StateError(
          'Une autre version a ete enregistree. Rouvrez le document.',
        );
      }
      final now = DateTime.now().toIso8601String();
      if (!preservePdfSidecars &&
          (current['annotations_json'] as String? ?? '').isNotEmpty) {
        await txn.insert('kv_store', {
          'key':
              'document_previous_revision:$documentId:${DateTime.now().microsecondsSinceEpoch}',
          'value': await OfflineVault.instance.sealString(jsonEncode(current)),
          'updated_at': now,
        });
      }
      final payload = await OfflineVault.instance.sealString(
        jsonEncode({
          'patientLocalId': current['patient_local_id'],
          'documentLocalId': documentId,
          if (revision != null) 'localPath': revision.path,
          if (dataUrl != null) 'dataUrl': dataUrl,
          'title': current['title'] as String? ?? 'Document',
          'fileName': publicFileName,
          'mimeType': mimeType,
          'tags': jsonDecode(current['tags_json'] as String? ?? '[]'),
        }),
      );
      await txn.delete(
        'sync_operations',
        where:
            'entity_local_id = ? AND entity_type = ? '
            'AND operation_type = ? AND status IN (?, ?, ?)',
        whereArgs: [
          documentId,
          'document',
          'upload_file',
          SyncOperationStatus.pending.name,
          SyncOperationStatus.running.name,
          SyncOperationStatus.failed.name,
        ],
      );
      await txn.update(
        'documents',
        {
          'local_file_path': revision?.path,
          'local_file_data_url': sealedDataUrl,
          'file_ext': extension,
          'mime_type': mimeType,
          'file_name': publicFileName,
          if (!preservePdfSidecars) 'annotations_json': null,
          'sync_state': SyncState.pendingSync.name,
          'updated_at': now,
        },
        where: 'local_id = ?',
        whereArgs: [documentId],
      );
      await txn.insert('sync_operations', {
        'id': operationId,
        'entity_type': 'document',
        'entity_local_id': documentId,
        'operation_type': 'upload_file',
        'payload_json': payload,
        'status': SyncOperationStatus.pending.name,
        'attempt_count': 0,
        'last_error': null,
        'created_at': now,
        'updated_at': now,
      });
      committedRow = (await txn.query(
        'documents',
        where: 'local_id = ?',
        whereArgs: [documentId],
        limit: 1,
      )).single;
    });

    SyncEngine().notify();
    _notifyChanged(
      patientId: snapshot['patient_local_id'] as String,
      dossierId: snapshot['dossier_local_id'] as String?,
      documentId: documentId,
      reason: annotated ? 'annotated_reupload' : 'replace_file',
    );
    return _mapRow(committedRow);
  }

  Future<void> updateDocumentMetadata({
    required String documentId,
    required String title,
    required List<String> tags,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'documents',
      columns: const ['patient_local_id', 'dossier_local_id'],
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    await db.update(
      'documents',
      {
        'title': title,
        'tags_json': jsonEncode(tags),
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    await _enqueueDocumentMetadataSync(
      documentId: documentId,
      title: title,
      tags: tags,
    );
    SyncEngine().notify();
    if (rows.isNotEmpty) {
      _notifyChanged(
        patientId: rows.first['patient_local_id'] as String? ?? '',
        dossierId: rows.first['dossier_local_id'] as String?,
        documentId: documentId,
        reason: 'update_metadata',
      );
    }
  }

  Future<void> _enqueueDocumentMetadataSync({
    required String documentId,
    required String title,
    required List<String> tags,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: const [
        'local_id',
        'patient_local_id',
        'dossier_local_id',
        'remote_file_path',
        'remote_public_url',
      ],
      where: 'local_id = ? AND pending_delete = 0',
      whereArgs: [documentId],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final row = rows.first;
    final patientId = (row['patient_local_id'] as String?) ?? '';
    if (patientId.isEmpty) return;

    final now = DateTime.now().toIso8601String();
    final remoteDocumentId = _extractRemoteIdFromRow(row, documentId);
    await db.insert('sync_operations', {
      'id': 'sync_doc_meta_$documentId',
      'entity_type': 'document',
      'entity_local_id': documentId,
      'operation_type': 'update_metadata',
      'payload_json': await OfflineVault.instance.sealString(
        jsonEncode({
          'patientLocalId': patientId,
          'documentLocalId': documentId,
          'remoteDocumentId': remoteDocumentId,
          'title': title,
          'tags': tags,
        }),
      ),
      'status': SyncOperationStatus.pending.name,
      'attempt_count': 0,
      'last_error': null,
      'created_at': now,
      'updated_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Persiste le chemin local d'un fichier distant téléchargé en cache.
  ///
  /// Local-only : on ne marque pas le document comme modifié et on ne crée
  /// aucune opération de sync. Le but est uniquement de permettre aux aperçus
  /// natifs (notamment PDF) de s'ouvrir instantanément aux prochains clics.
  Future<bool> storeLocalDocumentPath({
    required DocItem expectedDocument,
    required String localFilePath,
  }) async {
    final trimmedPath = localFilePath.trim();
    if (trimmedPath.isEmpty) return false;
    final db = await _database.database;
    final changed = await db.update(
      'documents',
      {'local_file_path': trimmedPath},
      where:
          'local_id = ? AND updated_at = ? '
          'AND COALESCE(remote_public_url, \'\') = ? '
          'AND COALESCE(local_file_path, \'\') = ? '
          'AND COALESCE(local_file_data_url, \'\') = \'\' '
          'AND pending_delete = 0 AND sync_state = ? '
          'AND NOT EXISTS (SELECT 1 FROM sync_operations op '
          'WHERE op.entity_type = \'document\' '
          'AND op.entity_local_id = documents.local_id '
          'AND op.status != \'completed\')',
      whereArgs: [
        expectedDocument.id,
        expectedDocument.updatedAt,
        expectedDocument.url ?? '',
        expectedDocument.localPath ?? '',
        SyncState.synced.name,
      ],
    );
    return changed == 1;
  }

  /// Met à jour la catégorisation visite d'un document — utilisé
  /// exclusivement par l'onglet Photos du relevé de visite.
  ///
  /// - [tags] : la liste cible (le caller a déjà calculé ce que la
  ///   nouvelle catégorie implique — ajout du tag visite, retrait des
  ///   éventuels autres tags visite, conservation des tags non-visite).
  /// - [categoryOrder] : position dans la catégorie. `null` quand le
  ///   document est retiré d'une catégorie visite (passe à « À classer »).
  ///
  /// `category_order` est purement local en v1 (pas d'envoi au serveur).
  /// La mise à jour des tags par contre est synchronisée à NocoDB via
  /// le sync engine pour qu'on retrouve le tag à la prochaine connexion.
  Future<void> setVisitCategorization({
    required String documentId,
    required List<String> tags,
    int? categoryOrder,
  }) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final rows = await db.query(
      'documents',
      columns: const ['title', 'patient_local_id', 'dossier_local_id'],
      where: 'local_id = ?',
      whereArgs: [documentId],
      limit: 1,
    );
    final title = rows.isNotEmpty
        ? ((rows.first['title'] as String?) ?? 'Document')
        : 'Document';
    await db.update(
      'documents',
      {
        'tags_json': jsonEncode(tags),
        'category_order': categoryOrder,
        'updated_at': now,
        'sync_state': SyncState.pendingSync.name,
      },
      where: 'local_id = ?',
      whereArgs: [documentId],
    );
    await _enqueueDocumentMetadataSync(
      documentId: documentId,
      title: title,
      tags: tags,
    );
    SyncEngine().notify();
    if (rows.isNotEmpty) {
      _notifyChanged(
        patientId: rows.first['patient_local_id'] as String? ?? '',
        dossierId: rows.first['dossier_local_id'] as String?,
        documentId: documentId,
        reason: 'visit_categorization',
      );
    }
  }

  /// Réordonne plusieurs documents d'une catégorie en une seule
  /// transaction. Appelé après un drag-to-reorder côté UI : le caller
  /// fournit la liste des `documentId` dans le NOUVEL ordre voulu et
  /// chacun reçoit son index comme `category_order`.
  Future<void> reorderVisitCategory({
    required List<String> orderedDocumentIds,
  }) async {
    if (orderedDocumentIds.isEmpty) return;
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (var i = 0; i < orderedDocumentIds.length; i++) {
      batch.update(
        'documents',
        {'category_order': i, 'updated_at': now},
        where: 'local_id = ?',
        whereArgs: [orderedDocumentIds[i]],
      );
    }
    await batch.commit(noResult: true);
    // Pas de notification au sync engine : `category_order` est local-only
    // pour l'instant. Si un autre champ change, c'est un autre code-path.
  }

  Future<void> hideObsoleteReportDocuments({
    required String patientId,
    required String dossierId,
    String keepLocalId = '',
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'documents',
      columns: const [
        'local_id',
        'dossier_local_id',
        'tags_json',
        'sync_state',
        'remote_file_path',
        'remote_public_url',
      ],
      where: 'patient_local_id = ? AND pending_delete = 0',
      whereArgs: [patientId],
    );

    final now = DateTime.now().toIso8601String();
    var changed = false;

    await db.transaction((txn) async {
      for (final row in rows) {
        final localId = (row['local_id'] as String?) ?? '';
        if (localId.isEmpty || localId == keepLocalId) continue;
        if (!_documentRowHasTag(row, 'Rapport')) continue;

        final rowDossierId = (row['dossier_local_id'] as String?) ?? '';
        if (rowDossierId.isNotEmpty && rowDossierId != dossierId) continue;

        changed = true;
        final wasSynced =
            (row['sync_state'] as String?) == SyncState.synced.name;
        final remoteId = _extractRemoteIdFromRow(row, localId);

        await txn.update(
          'documents',
          {
            'pending_delete': 1,
            'updated_at': now,
            'sync_state': SyncState.pendingSync.name,
          },
          where: 'local_id = ?',
          whereArgs: [localId],
        );

        await txn.delete(
          'sync_operations',
          where:
              'entity_local_id = ? AND operation_type = ? AND status IN (?, ?, ?)',
          whereArgs: [
            localId,
            'upload_file',
            SyncOperationStatus.pending.name,
            SyncOperationStatus.running.name,
            SyncOperationStatus.failed.name,
          ],
        );

        if (wasSynced && remoteId.isNotEmpty) {
          await txn.insert('sync_operations', {
            'id': 'sync_delete_$localId',
            'entity_type': 'document',
            'entity_local_id': localId,
            'operation_type': 'delete_document',
            'payload_json': await OfflineVault.instance.sealString(
              jsonEncode({'remoteDocumentId': remoteId}),
            ),
            'status': SyncOperationStatus.pending.name,
            'attempt_count': 0,
            'last_error': null,
            'created_at': now,
            'updated_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        } else {
          await txn.delete(
            'documents',
            where: 'local_id = ?',
            whereArgs: [localId],
          );
        }
      }
    });

    if (changed) SyncEngine().notify();
    if (changed) {
      _notifyChanged(
        patientId: patientId,
        dossierId: dossierId,
        reason: 'hide_obsolete_reports',
      );
    }
  }

  Future<void> deleteDocument(String documentId) async {
    final db = await _database.database;
    final now = DateTime.now().toIso8601String();

    final patientId = await db.transaction<String?>((txn) async {
      // Read the binding in the same transaction as deletion so an upload
      // acknowledgement cannot change the target between these operations.
      final rows = await txn.query(
        'documents',
        columns: const [
          'patient_local_id',
          'remote_file_path',
          'remote_public_url',
        ],
        where: 'local_id = ?',
        whereArgs: [documentId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final patientId = rows.first['patient_local_id'] as String? ?? '';
      final remoteId = _extractRemoteIdFromRow(rows.first, documentId);
      final runningUploads = await txn.query(
        'sync_operations',
        columns: const ['id'],
        where:
            'entity_type = ? AND entity_local_id = ? '
            'AND operation_type = ? AND status = ?',
        whereArgs: [
          'document',
          documentId,
          'upload_file',
          SyncOperationStatus.running.name,
        ],
        limit: 1,
      );
      // A running replacement may change the remote UUID. Its stable client
      // identity lets the later DELETE target the uploaded revision as well.
      final deletionId = runningUploads.isNotEmpty ? documentId : remoteId;
      // Keep deletion identities after the local row is purged: an older
      // in-flight listing must not recreate a successfully deleted document.
      for (final identity in <String>{
        documentId,
        remoteId,
        rows.first['remote_file_path'] as String? ?? '',
        rows.first['remote_public_url'] as String? ?? '',
      }.where((value) => value.isNotEmpty)) {
        await txn.insert('kv_store', {
          'key': 'document_deleted:${jsonEncode([patientId, identity])}',
          'value': now,
          'updated_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // Marque pending_delete pour cacher immédiatement le doc côté UI
      // (filtrage SQL `pending_delete = 0` dans `fetchDocuments`).
      await txn.update(
        'documents',
        {
          'pending_delete': 1,
          'updated_at': now,
          'sync_state': SyncState.pendingSync.name,
        },
        where: 'local_id = ?',
        whereArgs: [documentId],
      );

      // Keep running uploads tracked until completion; deleting their queue
      // row cannot cancel an HTTP request already being processed remotely.
      await txn.delete(
        'sync_operations',
        where:
            'entity_local_id = ? AND operation_type = ? AND status IN (?, ?)',
        whereArgs: [
          documentId,
          'upload_file',
          SyncOperationStatus.pending.name,
          SyncOperationStatus.failed.name,
        ],
      );

      if (deletionId.isNotEmpty) {
        // Enqueue un DELETE qui sera traité par `_processDocumentOperation`
        // côté sync engine. Sans cette op, la suppression locale n'était
        // JAMAIS propagée au serveur — au prochain pull NocoDB, le doc
        // était ressuscité (cf. audit critique #4).
        await txn.insert(
          'sync_operations',
          {
            'id': 'sync_delete_$documentId',
            'entity_type': 'document',
            'entity_local_id': documentId,
            'operation_type': 'delete_document',
            'payload_json': await OfflineVault.instance.sealString(
              jsonEncode({'remoteDocumentId': deletionId}),
            ),
            'status': SyncOperationStatus.pending.name,
            'attempt_count': 0,
            'last_error': null,
            'created_at': now,
            'updated_at': now,
          },
          // Idempotent : si l'utilisateur clique deux fois, on remplace
          // l'op précédente plutôt que de dupliquer.
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } else {
        // Doc jamais poussé — on peut purger directement le local.
        await txn.delete(
          'documents',
          where: 'local_id = ?',
          whereArgs: [documentId],
        );
      }
      return patientId;
    });
    if (patientId == null) return;

    SyncEngine().notify();
    _notifyChanged(
      patientId: patientId,
      documentId: documentId,
      reason: 'delete',
    );
  }

  bool _documentRowHasTag(Map<String, Object?> row, String tag) {
    final raw = row['tags_json'] as String? ?? '[]';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final expected = tag.trim().toLowerCase();
        return decoded.any(
          (value) => value.toString().trim().toLowerCase() == expected,
        );
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  /// Pour les documents synced, retrouve l'ID serveur utilisé par
  /// `DELETE /api/documents/<id>` et `PATCH /api/documents/<id>`.
  ///
  /// Les documents créés offline ont un `local_id` du type `doc_...`.
  /// Le serveur, lui, stocke un UUID et renvoie son URL
  /// `/api/mobile-documents/<uuid>/content`. Il faut donc extraire cet UUID
  /// en priorité ; sinon une mise à jour metadata part sur `/api/documents/doc_...`
  /// et revient en 404 "Document introuvable".
  String _extractRemoteIdFromRow(Map<String, Object?> row, String localId) {
    final candidates = [
      (row['remote_file_path'] as String?) ?? '',
      (row['remote_public_url'] as String?) ?? '',
    ];
    for (final raw in candidates) {
      final match = RegExp(
        r'/mobile-documents/([^/]+)/content',
      ).firstMatch(raw);
      if (match != null) {
        return Uri.decodeComponent(match.group(1) ?? '');
      }
    }

    if (localId.startsWith('remote_doc_')) {
      final stripped = localId.substring('remote_doc_'.length);
      if (stripped.isNotEmpty) return stripped;
    }

    if (localId.startsWith('doc_')) return '';
    return '';
  }

  String _remoteDocumentLocalId(String patientId, Map<String, dynamic> remote) {
    final remoteIdentity =
        [
              remote['id'],
              remote['sourceDocumentId'],
              remote['clientDocumentId'],
              remote['remotePath'],
              remote['publicUrl'],
            ]
            .map((value) => value?.toString().trim() ?? '')
            .firstWhere(
              (value) => value.isNotEmpty,
              orElse: () => jsonEncode(remote),
            );
    final patientKey = base64Url.encode(utf8.encode(patientId));
    final documentKey = base64Url.encode(utf8.encode(remoteIdentity));
    return 'remote_doc_${patientKey}_$documentKey';
  }

  Future<void> mergeRemoteDocuments(
    String patientId,
    List<Map<String, dynamic>> remoteDocuments,
  ) async {
    final db = await _database.database;

    // Set canonique des `local_id` qui existent côté NocoDB pour ce
    // patient — alimenté pendant la boucle pour réconcilier ensuite
    // les suppressions remote (chantier sync #1).
    final remoteLocalIds = <String>{};

    await db.transaction((txn) async {
      for (final remote in remoteDocuments) {
        final deletionIdentities = <String>{
          for (final key in const [
            'id',
            'sourceDocumentId',
            'clientDocumentId',
            'remotePath',
            'publicUrl',
          ])
            if ((remote[key]?.toString() ?? '').isNotEmpty)
              remote[key].toString(),
          _remoteDocumentLocalId(patientId, remote),
        };
        final deleted = await txn.query(
          'kv_store',
          columns: const ['key'],
          where:
              'key IN (${List.filled(deletionIdentities.length, '?').join(',')})',
          whereArgs: [
            for (final identity in deletionIdentities)
              'document_deleted:${jsonEncode([patientId, identity])}',
          ],
          limit: 1,
        );
        if (deleted.isNotEmpty) continue;
        final remotePath = remote['remotePath']?.toString();
        final publicUrl = remote['publicUrl']?.toString();
        // Server echoes the Flutter-assigned local id as `clientDocumentId`
        // → used here as the primary match key. Prevents duplicates when
        // the sync push lands before `storeDocumentRemoteData` populates
        // the remote_file_path/remote_public_url columns.
        final clientDocumentId = remote['clientDocumentId']?.toString() ?? '';

        final aliases = clientDocumentId.isEmpty
            ? <Map<String, Object?>>[]
            : await txn.query(
                'kv_store',
                columns: ['key'],
                where: 'value = ? AND key LIKE ?',
                whereArgs: [clientDocumentId, 'document_upload_identity:%'],
              );
        final aliasIds = <String>[];
        for (final alias in aliases) {
          final identity =
              jsonDecode(
                    (alias['key'] as String).substring(
                      'document_upload_identity:'.length,
                    ),
                  )
                  as List;
          if (identity[0] == patientId) aliasIds.add(identity[1] as String);
        }

        final existingRows = await txn.query(
          'documents',
          where: clientDocumentId.isNotEmpty
              ? 'patient_local_id = ? AND '
                    '(local_id = ? OR remote_file_path = ? OR remote_public_url = ? ${aliasIds.isEmpty ? '' : 'OR local_id IN (${List.filled(aliasIds.length, '?').join(',')})'})'
              : 'patient_local_id = ? AND '
                    '(remote_file_path = ? OR remote_public_url = ?)',
          whereArgs: clientDocumentId.isNotEmpty
              ? [
                  patientId,
                  clientDocumentId,
                  remotePath,
                  publicUrl,
                  ...aliasIds,
                ]
              : [patientId, remotePath, publicUrl],
          limit: 1,
        );

        final existing = existingRows.isNotEmpty ? existingRows.first : null;
        final existingSyncState = existing?['sync_state'] as String?;
        final remoteDate = DateTime.tryParse(
          remote['updatedAt']?.toString() ?? '',
        );
        if (existing != null) {
          // Include protected rows in reconciliation before any early return.
          remoteLocalIds.add(existing['local_id'] as String);
          final pending = await txn.query(
            'sync_operations',
            columns: const ['id'],
            where: 'entity_type = ? AND entity_local_id = ? AND status != ?',
            whereArgs: ['document', existing['local_id'], 'completed'],
            limit: 1,
          );
          if (pending.isNotEmpty) continue;

          final retiredRows = await txn.query(
            'kv_store',
            where: 'key = ?',
            whereArgs: ['document_retired_content:${existing['local_id']}'],
            limit: 1,
          );
          if (retiredRows.isNotEmpty) {
            final retired =
                (jsonDecode(retiredRows.single['value'] as String) as List)
                    .cast<String>();
            final incomingIdentity = (remotePath ?? '').isNotEmpty
                ? remotePath
                : publicUrl;
            final currentIdentity =
                (existing['remote_file_path'] as String? ?? '').isNotEmpty
                ? existing['remote_file_path']
                : existing['remote_public_url'];
            if (incomingIdentity != currentIdentity &&
                retired.contains(incomingIdentity)) {
              continue;
            }
          }

          final versions = await txn.query(
            'kv_store',
            where: 'key = ?',
            whereArgs: ['document_remote_version:${existing['local_id']}'],
            limit: 1,
          );
          if (versions.isNotEmpty && remoteDate != null) {
            final version =
                jsonDecode(versions.single['value'] as String) as Map;
            final acceptedDate = DateTime.tryParse(
              version['updatedAt'] as String? ?? '',
            );
            // Compare server timestamps only: the iPad clock and upload ACK
            // timestamp are not a remote revision clock.
            if (acceptedDate != null &&
                (remoteDate.isBefore(acceptedDate) ||
                    (remoteDate.isAtSameMomentAs(acceptedDate) &&
                        version['remotePath'] == remotePath &&
                        remotePath != existing['remote_file_path']))) {
              continue;
            }
          }
          // A newer server clock cannot acknowledge an unpublished edit.
          // Keep the local photo/document even if its queue entry is missing.
          if (existingSyncState != SyncState.synced.name) {
            continue;
          }
        }
        // Anti-resurrection : si l'utilisateur a supprimé le doc localement
        // (pending_delete=1) et que le DELETE remote n'a pas encore été
        // traité par le sync engine, on évite de l'écraser en `synced`
        // (sinon il réapparaît dans l'UI). On laisse la `sync_operations`
        // (delete_document) faire le DELETE distant + purger le local.
        if (existing != null &&
            (existing['pending_delete'] as int? ?? 0) == 1) {
          continue;
        }

        final rawFileName = remote['fileName']?.toString() ?? 'document';
        final title = remote['title']?.toString() ?? rawFileName;
        final mimeType = remote['mimeType']?.toString();
        final fileName = publicDocumentFileName(
          storedName: rawFileName,
          title: title,
          mimeType: mimeType,
        );
        final extension = documentFileExtension(
          storedName: fileName,
          mimeType: mimeType,
        ).replaceFirst('.', '').toLowerCase();
        final localId =
            existing?['local_id'] as String? ??
            _remoteDocumentLocalId(patientId, remote);
        await storeDocumentUploadIdentity(
          txn,
          patientId,
          localId,
          clientDocumentId,
        );
        remoteLocalIds.add(localId);
        // The backend allocates a new content UUID/path on replacement.
        // Timestamps alone also change on rename, so keep those local bytes.
        final contentChanged =
            existing != null &&
            ((remotePath != null &&
                    remotePath.isNotEmpty &&
                    (existing['remote_file_path'] as String? ?? '')
                        .isNotEmpty &&
                    existing['remote_file_path'] != remotePath) ||
                ((existing['remote_file_path'] as String? ?? '').isEmpty &&
                    (existing['remote_public_url'] as String? ?? '')
                        .isNotEmpty &&
                    publicUrl != null &&
                    publicUrl.isNotEmpty &&
                    existing['remote_public_url'] != publicUrl));
        if (contentChanged) {
          // Keep a recoverable snapshot, including encrypted web overlays,
          // without applying annotations from the previous PDF to the new one.
          await txn.insert('kv_store', {
            'key':
                'document_previous_revision:$localId:${DateTime.now().microsecondsSinceEpoch}',
            'value': await OfflineVault.instance.sealString(
              jsonEncode(existing),
            ),
            'updated_at': DateTime.now().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        final row = {
          if (existing != null) ...existing,
          'local_id': localId,
          'patient_local_id': patientId,
          'title': title,
          'file_name': fileName,
          'file_ext': extension,
          'mime_type': mimeType ?? _mimeTypeFor(extension),
          'local_file_path': contentChanged
              ? null
              : existing?['local_file_path'],
          // Preserve offline bytes on metadata refresh, not on replacement.
          'local_file_data_url': contentChanged
              ? null
              : existing?['local_file_data_url'],
          'remote_file_path': remotePath,
          'remote_public_url': publicUrl,
          'tags_json': jsonEncode(
            (remote['tags'] as List?)?.map((tag) => '$tag').toList() ??
                const <String>[],
          ),
          // CRITICAL aussi : `category_order` (ordre de la photo dans
          // sa catégorie de l'onglet Photos du relevé) est local-only
          // — le serveur ne le connaît pas. Sans cette préservation,
          // le polling silencieux de `_loadDocuments` (toutes les 10 s)
          // remet TOUTES les photos visite à `category_order = NULL` →
          // le tri perd son sens.
          'category_order':
              existing?['category_order'] ?? remote['category_order'],
          // Overlays belong to the old content, archived above on replacement.
          'annotations_json': contentChanged
              ? null
              : existing?['annotations_json'],
          'created_at':
              remote['createdAt']?.toString() ??
              existing?['created_at'] as String? ??
              DateTime.now().toIso8601String(),
          'updated_at':
              remote['updatedAt']?.toString() ??
              existing?['updated_at'] as String? ??
              DateTime.now().toIso8601String(),
          'sync_state': SyncState.synced.name,
          'pending_delete': existing?['pending_delete'] ?? 0,
        };

        await txn.insert(
          'documents',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        if (remoteDate != null) {
          await txn.insert('kv_store', {
            'key': 'document_remote_version:$localId',
            'value': jsonEncode({
              'remotePath': remotePath,
              'updatedAt': remoteDate.toIso8601String(),
            }),
            'updated_at': remoteDate.toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      // ----------------------------------------------------------------
      // Réconciliation des suppressions NocoDB scopée à ce patient.
      // Toute ligne `synced` (donc déjà connue du serveur) qui n'est
      // PAS dans le set canonique remote est purgée. Les drafts
      // (sync_state != synced) et les soft-deletes (pending_delete=1)
      // sont préservés.
      //
      // Filtre temporel : on ne purge que les docs créés il y a plus
      // de 5 minutes. Protection contre la consistance éventuelle de
      // NocoDB — un doc uploadé < 5 min plus tôt peut ne pas encore
      // figurer dans la pull list. Au prochain pull (≥ 5 min plus
      // tard), si le doc reste absent, on purge.
      //
      // Une liste distante vide n'est pas une preuve de suppression :
      // elle peut aussi provenir d'une restauration incomplète après
      // réinstallation ou d'une lecture NocoDB momentanément partielle.
      // On privilégie donc la conservation locale. La suppression
      // explicite reste propagée par l'opération `delete_document`.
      // ----------------------------------------------------------------
      if (remoteLocalIds.isEmpty) {
        return;
      }

      final ageThreshold = DateTime.now().subtract(const Duration(minutes: 5));
      final args = <Object?>[
        patientId,
        SyncState.synced.name,
        ageThreshold.toIso8601String(),
      ];
      String whereClause =
          'patient_local_id = ? AND sync_state = ? '
          'AND pending_delete = 0 '
          'AND created_at < ?';
      final placeholders = List.filled(remoteLocalIds.length, '?').join(',');
      whereClause += ' AND local_id NOT IN ($placeholders)';
      whereClause +=
          " AND NOT EXISTS (SELECT 1 FROM sync_operations op "
          "WHERE op.entity_type = 'document' "
          "AND op.entity_local_id = documents.local_id "
          "AND op.status != 'completed')";
      args.addAll(remoteLocalIds);
      final deleted = await txn.delete(
        'documents',
        where: whereClause,
        whereArgs: args,
      );
      if (deleted > 0) {
        // ignore: avoid_print
        print(
          '[reconcile] documents (patient=$patientId) : '
          '$deleted ligne(s) purgée(s) (suppression remote, âge > 5min)',
        );
      }
    });

    // Warm the media cache so document previews (PDFs, images) work offline
    // after the first sync of this dossier.
    if (prefetchRemoteAssets) {
      unawaited(prefetchDocumentAssets(patientId));
    }
  }

  /// Hydrate accepted database revisions only, never the raw pull response.
  /// A late download must still match its snapshot before it can be attached.
  Future<void> prefetchDocumentAssets(String patientId) async {
    try {
      final db = await _database.database;
      final rows = await db.query(
        'documents',
        where:
            "patient_local_id = ? AND sync_state = 'synced' "
            "AND pending_delete = 0 "
            "AND NOT EXISTS (SELECT 1 FROM sync_operations op "
            "WHERE op.entity_type = 'document' "
            "AND op.entity_local_id = documents.local_id "
            "AND op.status != 'completed')",
        whereArgs: [patientId],
      );
      for (final row in rows) {
        try {
          if ((row['local_file_data_url'] as String? ?? '').isNotEmpty) {
            continue;
          }
          final doc = await _mapRow(row);
          final url = documentPreviewUrl(doc);
          if (url.isEmpty) continue;
          final path = doc.localPath ?? '';
          if (!kIsWeb && path.isNotEmpty && await File(path).exists()) continue;
          if (kIsWeb) {
            await MediaCacheService.instance.webCachedFetch(
              url,
              headers: MediaCacheService.authHeadersFor(url),
            );
            continue;
          }
          final cached =
              await (_remoteFileFetcher?.call(url) ??
                  MediaCacheService.instance.fetch(
                    url,
                    headers: MediaCacheService.authHeadersFor(url),
                  ));
          if (cached == null) continue;
          final revision = await _revisionStore.prepare(
            extension: (row['file_ext'] as String? ?? '').isEmpty
                ? 'bin'
                : row['file_ext'] as String,
            sourceFile: cached,
          );
          final attached = await storeLocalDocumentPath(
            expectedDocument: doc,
            localFilePath: revision.path,
          );
          if (!attached) {
            // This private, unpublished directory cannot be in use by a viewer.
            await revision.parent.delete(recursive: true);
          }
        } catch (error) {
          // One failed/offline document must not stop the rest of the dossier.
          // ignore: avoid_print
          print('[docs prefetch] document unavailable (${error.runtimeType})');
        }
      }
    } catch (error) {
      // ignore: avoid_print
      print('[docs prefetch] unavailable (${error.runtimeType})');
    }
  }

  Future<DocItem> _mapRow(Map<String, Object?> row) async {
    final rawFileName = row['file_name'] as String? ?? '';
    final title = row['title'] as String? ?? rawFileName;
    final mimeType = row['mime_type'] as String? ?? '';
    final storedExt = (row['file_ext'] as String? ?? '')
        .replaceFirst('.', '')
        .toLowerCase();
    final inferredExt = documentFileExtension(
      storedName: rawFileName,
      mimeType: mimeType,
    ).replaceFirst('.', '').toLowerCase();
    final ext = inferredExt == 'bin' && storedExt.isNotEmpty
        ? storedExt
        : inferredExt;
    final type = _typeForExtension(ext, mimeType: mimeType);
    final rawTags = row['tags_json'] as String? ?? '[]';
    final decodedTags = (jsonDecode(rawTags) as List<dynamic>).cast<String>();
    final isReport = decodedTags.any(
      (tag) => tag.trim().toLowerCase() == 'rapport',
    );
    final createdAt = row['created_at'] as String;
    final updatedAt = row['updated_at'] as String? ?? createdAt;

    final dataUrl = await OfflineVault.instance.openNullableString(
      row['local_file_data_url'] as String?,
    );
    final annotationsJson = await OfflineVault.instance.openNullableString(
      row['annotations_json'] as String?,
    );
    var localPath = row['local_file_path'] as String?;
    if (!kIsWeb && localPath != null && localPath.trim().isNotEmpty) {
      localPath = await resolveDocumentStoragePath(localPath);
      await NativeFileProtection.instance.protectPath(localPath);
    }

    return DocItem(
      id: row['local_id'] as String,
      type: type,
      name: publicDocumentFileName(
        storedName: rawFileName,
        title: title,
        mimeType: mimeType,
        type: type,
      ),
      title: title,
      url: row['remote_public_url'] as String?,
      date: isReport ? updatedAt : createdAt,
      updatedAt: updatedAt,
      localPath: localPath,
      // Web-only: the freshly captured bytes as a data URL. Populated by
      // `importDocumentBytes` on web and cleared once the sync processor
      // uploads them.
      dataUrl: dataUrl,
      tags: decodedTags,
      syncState: SyncState.values.byName(row['sync_state'] as String),
      categoryOrder: (row['category_order'] as num?)?.toInt(),
      annotationsJson: annotationsJson,
    );
  }

  String _typeForExtension(String extension, {String mimeType = ''}) {
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(extension)) {
      return 'image';
    }
    if (mimeType.toLowerCase().startsWith('image/')) return 'image';
    if (extension == 'pdf') return 'pdf';
    if (mimeType.toLowerCase() == 'application/pdf') return 'pdf';
    return 'doc';
  }

  String _mimeTypeFor(String extension) {
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }
}

/// Container plat pour un document à embarquer **inline** dans la
/// requête HTTP de génération PDF. Construit par
/// [DocumentRepository.fetchVisitReportInlineBytes].
///
/// Les champs `tags`, `title`, `dossierId`, `mimeType` sont sérialisés
/// dans un champ multipart `inline_doc_<localId>_meta` (JSON). Les
/// `bytes` sont attachés comme `MultipartFile` avec le fieldname
/// `inline_doc_<localId>`. Côté serveur, cf.
/// `parseInlineReportAssets()` dans `server/index.mjs`.
class InlineDocumentBytes {
  InlineDocumentBytes({
    required this.localId,
    required this.fileName,
    required this.mimeType,
    required this.tags,
    required this.bytes,
    this.title = '',
    this.categoryOrder,
    this.dossierId,
  });

  final String localId;
  final String fileName;
  final String mimeType;
  final List<String> tags;
  final String title;
  final int? categoryOrder;
  final String? dossierId;
  final Uint8List bytes;
}

/// Métadonnée légère envoyée avec la génération PDF pour refléter
/// immédiatement l'ordre local des photos déjà synchronisées.
class InlineDocumentOrder {
  const InlineDocumentOrder({
    required this.localId,
    required this.categoryOrder,
  });

  final String localId;
  final int categoryOrder;
}
