import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

class DatabaseUnavailableScreen extends StatefulWidget {
  const DatabaseUnavailableScreen({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  State<DatabaseUnavailableScreen> createState() =>
      _DatabaseUnavailableScreenState();
}

class _DatabaseUnavailableScreenState extends State<DatabaseUnavailableScreen> {
  bool _retrying = false;

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // Keep the recovery screen; never replace the inaccessible store.
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(LucideIcons.database, size: 36),
                const SizedBox(height: 20),
                Text(
                  'Stockage local indisponible',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                const Text(
                  "Les fichiers locaux sont conserv\u00e9s. L'application ne peut pas les ouvrir pour le moment.",
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _retrying ? null : _retry,
                  icon: _retrying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(LucideIcons.refreshCw, size: 18),
                  label: const Text('R\u00e9essayer'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
