import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../services/local_database.dart';
import '../services/app_config.dart';
import '../services/offline_vault.dart';
import '../services/sync_operation_ownership.dart';

typedef SyncPayloadOpener = Future<String> Function(String sealedPayload);

class SyncOwnershipReviewScreen extends StatefulWidget {
  const SyncOwnershipReviewScreen({
    super.key,
    required this.database,
    this.openPayload,
    this.onReviewed,
  });

  final LocalDatabase database;
  final SyncPayloadOpener? openPayload;
  final VoidCallback? onReviewed;

  @override
  State<SyncOwnershipReviewScreen> createState() =>
      _SyncOwnershipReviewScreenState();
}

class _SyncOwnershipReviewScreenState extends State<SyncOwnershipReviewScreen> {
  ReviewableSyncOperation? _operation;
  String _summary = '';
  String _target = '';
  String? _reviewerId;
  int? _reviewEpoch;
  bool _readable = false;
  bool _waitingForOwner = false;
  bool _loading = true;
  bool _submitting = false;
  bool _confirmed = false;
  bool _forbidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNext());
  }

  Future<void> _loadNext() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _submitting = false;
        _confirmed = false;
        _error = null;
      });
    }
    try {
      final epoch = AppConfig.sessionEpoch;
      final db = await widget.database.database;
      final loaded = await db.transaction((txn) async {
        final counts = await SyncOperationOwnership.blockedCounts(txn);
        final adminId = await _activeAdminId(txn);
        if (adminId == null &&
            counts.historicalUnattributed +
                    counts.reviewRequired +
                    counts.missingOwnership >
                0) {
          throw const _AdminRequired();
        }
        final rows = await SyncOperationOwnership.listReviewableOperations(txn);
        final operation = rows.isEmpty ? null : rows.single;
        final target = operation == null
            ? ''
            : await _targetLabel(txn, operation);
        return (operation, adminId, counts.ownerMismatch > 0, target);
      });
      final operation = loaded.$1;
      final summary = operation == null
          ? ('', false)
          : await _buildSafeSummary(operation);
      if (epoch != AppConfig.sessionEpoch ||
          (operation != null && await _activeAdminId(db) != loaded.$2)) {
        throw const _AdminRequired();
      }
      if (!mounted) return;
      setState(() {
        _operation = operation;
        _summary = summary.$1;
        _readable = summary.$2;
        _target = loaded.$4;
        _reviewerId = loaded.$2;
        _reviewEpoch = epoch;
        _waitingForOwner = loaded.$3;
        _loading = false;
        _forbidden = false;
      });
    } on _AdminRequired {
      if (!mounted) return;
      setState(() {
        _operation = null;
        _loading = false;
        _forbidden = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _operation = null;
        _loading = false;
        _error = 'La revue locale est momentanément indisponible.';
      });
    }
  }

  Future<(String, bool)> _buildSafeSummary(
    ReviewableSyncOperation operation,
  ) async {
    try {
      final open = widget.openPayload ?? OfflineVault.instance.openString;
      final decoded = jsonDecode(await open(operation.sealedPayloadJson));
      if (decoded is! Map) {
        return ('Le contenu protégé ne peut pas être résumé.', false);
      }
      final map = decoded.cast<String, dynamic>();
      final updates = map['updates'];
      final keys = updates is Map ? updates.keys : map.keys;
      final safeFields = keys
          .map((key) => key.toString())
          .where(_isSafeFieldName)
          .map(_readableFieldName)
          .toSet()
          .take(6)
          .toList(growable: false);
      if (safeFields.isEmpty) {
        return ('Contenu protégé. Les valeurs ne sont pas affichées.', true);
      }
      return ('Champs concernés : ${safeFields.join(', ')}.', true);
    } catch (_) {
      return (
        'Lecture impossible. La sauvegarde reste conservée sans être envoyée.',
        false,
      );
    }
  }

  bool _isSafeFieldName(String field) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(field)) return false;
    final normalized = field.toLowerCase();
    return !const [
      'token',
      'secret',
      'password',
      'authorization',
      'base64',
      'dataurl',
      'data_url',
      'bytes',
      'payload',
      'content',
      'image',
    ].any(normalized.contains);
  }

  String _readableFieldName(String field) {
    final spaced = field
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (match) => '${match.group(1)} ${match.group(2)}',
        )
        .replaceAll('_', ' ')
        .trim();
    if (spaced.isEmpty) return 'champ';
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }

  Future<void> _reviewCurrent() async {
    final operation = _operation;
    if (operation == null || !_confirmed || _submitting || !_readable) return;
    setState(() => _submitting = true);
    try {
      final db = await widget.database.database;
      final accepted = await db.transaction((txn) async {
        if (_reviewEpoch != AppConfig.sessionEpoch ||
            _reviewerId == null ||
            await _activeAdminId(txn) != _reviewerId) {
          throw const _AdminRequired();
        }
        final accepted = await SyncOperationOwnership.reviewAttribution(
          txn: txn,
          operationId: operation.operationId,
          expectedPayloadJson: operation.sealedPayloadJson,
          expectedPreviousOwnerUserLocalId: operation.ownerUserLocalId,
        );
        if (_reviewEpoch != AppConfig.sessionEpoch) {
          throw const _AdminRequired();
        }
        return accepted;
      });
      if (accepted) widget.onReviewed?.call();
      if (!mounted) return;
      if (!accepted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cette opération a changé pendant la revue. Vérifiez-la à nouveau.',
            ),
          ),
        );
        await _loadNext();
        return;
      }
      await _loadNext();
    } on _AdminRequired {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _forbidden = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'La décision n’a pas été enregistrée.';
      });
    }
  }

  Future<String?> _activeAdminId(DatabaseExecutor txn) async {
    final rows = await txn.rawQuery('''
      SELECT user.local_id
      FROM app_session AS session
      JOIN app_users AS user
        ON user.local_id = session.user_local_id
      WHERE session.id = 1
        AND user.is_active = 1
        AND LOWER(user.role) = 'admin'
      LIMIT 1
    ''');
    return rows.isEmpty ? null : rows.single['local_id'] as String;
  }

  Future<String> _targetLabel(
    DatabaseExecutor db,
    ReviewableSyncOperation op,
  ) async {
    try {
      final List<Map<String, Object?>> rows;
      if (op.entityType == 'document') {
        rows = await db.rawQuery(
          'SELECT title AS label FROM documents WHERE local_id = ?',
          [op.entityLocalId],
        );
      } else if (op.entityType == 'patient') {
        rows = await db.rawQuery(
          "SELECT first_name || ' ' || last_name AS label FROM patients WHERE local_id = ?",
          [op.entityLocalId],
        );
      } else {
        rows = await db.rawQuery(
          "SELECT p.first_name || ' ' || p.last_name AS label FROM dossiers d JOIN patients p ON p.local_id = d.patient_local_id WHERE d.local_id = ?",
          [op.entityLocalId],
        );
      }
      if (rows.isNotEmpty &&
          (rows.first['label'] as String? ?? '').trim().isNotEmpty) {
        return rows.first['label'] as String;
      }
    } on DatabaseException {
      // An unavailable legacy target must not hide its queued intent.
    }
    return op.entityLocalId;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Revue des sauvegardes locales')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: _buildBody(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const CircularProgressIndicator();
    if (_forbidden) {
      return const _ReviewMessage(
        icon: Icons.lock_outline,
        title: 'Accès administrateur requis',
        message:
            'Vos sauvegardes restent conservées sur ce navigateur ou cet appareil. '
            'Un administrateur doit vérifier leur attribution ici, avec vous. '
            'Réessayer la synchronisation ne suffit pas dans ce cas. '
            'Ne videz pas les données de l’application et ne supprimez pas les '
            'sauvegardes en attente. Utilisez « Signaler » depuis la page précédente '
            'pour demander une intervention, sans transmettre le contenu des sauvegardes.',
      );
    }
    if (_error != null) {
      return _ReviewMessage(
        icon: Icons.error_outline,
        title: 'Revue indisponible',
        message: _error!,
        action: TextButton(
          onPressed: _loadNext,
          child: const Text('Réessayer'),
        ),
      );
    }
    final operation = _operation;
    if (operation == null) {
      if (_waitingForOwner) {
        return const _ReviewMessage(
          icon: Icons.person_outline,
          title: 'Reconnexion de l’auteur nécessaire',
          message:
              'Ces sauvegardes appartiennent à un autre compte. Connectez leur auteur pour reprendre leur envoi. Elles sont conservées sur cet appareil.',
        );
      }
      return const _ReviewMessage(
        icon: Icons.check_circle_outline,
        title: 'Aucune sauvegarde à attribuer',
        message: 'La file locale ne contient plus d’auteur ambigu à examiner.',
      );
    }

    final isRunning = operation.status == 'running';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_entityLabel(operation.entityType)} · '
          '${_operationLabel(operation.operationType)}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(_target, key: const ValueKey('ownership-target')),
        const SizedBox(height: 8),
        Text('État local : ${_statusLabel(operation.status)}'),
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFF4F5F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFD8DBDE)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_summary),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          operation.ownerUserLocalId == null
              ? 'Auteur historique inconnu.'
              : operation.candidateUserLocalId == null
              ? 'Cette sauvegarde possède un auteur historique.'
              : 'Deux comptes ont modifié cette sauvegarde. Les versions sont conservées.',
        ),
        if (isRunning) ...[
          const SizedBox(height: 12),
          const Text(
            'Cette opération est en cours. Elle ne peut pas être attribuée maintenant.',
          ),
        ],
        const SizedBox(height: 20),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _confirmed,
          onChanged: isRunning || _submitting || !_readable
              ? null
              : (value) => setState(() => _confirmed = value ?? false),
          title: const Text(
            'J’ai vérifié cette opération et je prends en charge son envoi avec mon compte.',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: isRunning || !_confirmed || _submitting || !_readable
              ? null
              : _reviewCurrent,
          child: Text(
            _submitting ? 'Enregistrement…' : 'Confirmer cette opération',
          ),
        ),
      ],
    );
  }

  String _entityLabel(String entityType) => switch (entityType) {
    'dossier' => 'Dossier',
    'patient' => 'Bénéficiaire',
    'housing' => 'Logement',
    'document' => 'Document',
    'note_page' => 'Note',
    'visit_recommendations' => 'Préconisations',
    _ => 'Sauvegarde locale',
  };

  String _operationLabel(String operationType) => switch (operationType) {
    'create' => 'Création',
    'update' => 'Modification',
    'delete' => 'Suppression',
    'upload' => 'Envoi de fichier',
    _ => 'Opération',
  };

  String _statusLabel(String status) => switch (status) {
    'pending' => 'en attente',
    'failed' => 'en échec',
    'conflict' => 'en conflit',
    'running' => 'en cours',
    _ => 'à vérifier',
  };
}

class _ReviewMessage extends StatelessWidget {
  const _ReviewMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 40),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(message, textAlign: TextAlign.center),
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    );
  }
}

class _AdminRequired implements Exception {
  const _AdminRequired();
}
