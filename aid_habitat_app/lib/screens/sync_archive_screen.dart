import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../components/brand_colors.dart';
import '../models/sync_archive_entry.dart';
import '../services/nocodb_api_client.dart';

/// Écran admin : valeurs que le serveur a conservées avant qu'un envoi les
/// remplace, avec possibilité de remettre une valeur en place.
class SyncArchiveScreen extends StatefulWidget {
  const SyncArchiveScreen({super.key, this.load, this.restore});

  /// Injectables pour les tests ; par défaut l'API du serveur.
  final Future<List<SyncArchiveEntry>> Function()? load;
  final Future<void> Function(String entryId)? restore;

  @override
  State<SyncArchiveScreen> createState() => _SyncArchiveScreenState();
}

class _SyncArchiveScreenState extends State<SyncArchiveScreen> {
  late final NocodbApiClient _api = NocodbApiClient();
  List<SyncArchiveEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  String _query = '';
  String? _restoringId;

  Future<List<SyncArchiveEntry>> _load() =>
      widget.load?.call() ?? _api.fetchSyncArchive();
  Future<void> _restore(String id) =>
      widget.restore?.call(id) ?? _api.restoreSyncArchiveEntry(id);

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _load();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  Future<void> _confirmRestore(SyncArchiveEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restaurer cette valeur ?'),
        content: Text(
          '${_fieldLabel(entry)} de ${entry.beneficiaryName ?? 'ce bénéficiaire'} '
          'reprendra la valeur :\n\n${describeArchivedValue(entry.previous)}\n\n'
          'La valeur actuelle sera elle-même archivée : vous pourrez revenir '
          'en arrière.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restaurer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _restoringId = entry.id);
    try {
      await _restore(entry.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Valeur restaurée.')),
      );
      await _reload();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
          backgroundColor: const Color(0xFFB91C1C),
        ),
      );
    } finally {
      if (mounted) setState(() => _restoringId = null);
    }
  }

  List<SyncArchiveEntry> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries
        .where(
          (e) =>
              (e.beneficiaryName ?? '').toLowerCase().contains(q) ||
              e.tableLabel.toLowerCase().contains(q) ||
              _fieldLabel(e).toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Valeurs archivées'),
        actions: [
          IconButton(
            tooltip: 'Actualiser',
            onPressed: _loading ? null : _reload,
            icon: const Icon(LucideIcons.refreshCw),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _Message(icon: LucideIcons.alertTriangle, text: _error!)
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(LucideIcons.search),
                      hintText: 'Rechercher un bénéficiaire, une fiche, un champ',
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                Expanded(
                  child: _visible.isEmpty
                      ? const _Message(
                          icon: LucideIcons.archive,
                          text: 'Aucune valeur archivée. Rien n\'a été écrasé.',
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                          itemCount: _visible.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 12),
                          itemBuilder: (_, index) => _EntryCard(
                            entry: _visible[index],
                            restoring: _restoringId == _visible[index].id,
                            onRestore: _restoringId == null
                                ? () => _confirmRestore(_visible[index])
                                : null,
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

String _fieldLabel(SyncArchiveEntry entry) => switch (entry.field) {
  'medicalContext' => 'Contexte médical',
  'autonomy' => 'Autonomie',
  _ => entry.field.replaceAll('_', ' '),
};

String _date(DateTime? value) {
  if (value == null) return 'date inconnue';
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(value.day)}/${two(value.month)}/${value.year} '
      'à ${two(value.hour)} h ${two(value.minute)}';
}

class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.entry,
    required this.restoring,
    required this.onRestore,
  });

  final SyncArchiveEntry entry;
  final bool restoring;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: const Color(0xFF6B7280),
    );
    return Card(
      key: ValueKey('sync-archive-${entry.id}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${entry.beneficiaryName ?? 'Bénéficiaire inconnu'} · '
              '${entry.tableLabel} · ${_fieldLabel(entry)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '${entry.source == 'restore' ? 'Remplacée lors d\'une restauration' : 'Remplacée'} '
              'le ${_date(entry.archivedAt)}'
              '${entry.actor == null ? '' : ' par ${entry.actor}'}',
              style: muted,
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = [
                  _ValueBlock(
                    title: 'Valeur remplacée',
                    value: entry.previous,
                  ),
                  _ValueBlock(
                    title: 'Valeur qui l\'a remplacée',
                    value: entry.next,
                  ),
                ];
                return constraints.maxWidth < 520
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          columns[0],
                          const SizedBox(height: 8),
                          columns[1],
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: columns[0]),
                          const SizedBox(width: 16),
                          Expanded(child: columns[1]),
                        ],
                      );
              },
            ),
            const SizedBox(height: 12),
            if (entry.isRestored)
              Text(
                'Restaurée le ${_date(entry.restoredAt)}',
                style: muted?.copyWith(color: const Color(0xFF15803D)),
              )
            else
              FilledButton.icon(
                onPressed: onRestore,
                style: FilledButton.styleFrom(backgroundColor: kBrandPurple),
                icon: restoring
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(LucideIcons.rotateCcw, size: 16),
                label: const Text('Restaurer cette valeur'),
              ),
          ],
        ),
      ),
    );
  }
}

class _ValueBlock extends StatelessWidget {
  const _ValueBlock({required this.title, required this.value});

  final String title;
  final Object? value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F5F9),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          SelectableText(describeArchivedValue(value)),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: const Color(0xFF6B7280)),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
