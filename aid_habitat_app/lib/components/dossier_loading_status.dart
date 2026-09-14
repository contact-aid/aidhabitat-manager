import 'package:flutter/material.dart';

class DossierLoadingStatus extends StatelessWidget {
  const DossierLoadingStatus({
    super.key,
    required this.offline,
    required this.failed,
    required this.onRetry,
  });
  final bool offline;
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!offline && !failed) const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            offline
                ? 'Aucun dossier disponible hors connexion sur cet appareil.'
                : failed
                ? 'Impossible de charger les dossiers pour le moment.'
                : 'Chargement des dossiers...',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Réessayer')),
        ],
      ),
    ),
  );
}
