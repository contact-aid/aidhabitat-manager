import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/sync_repository.dart';

Future<void> showSyncOperationDiagnostic(
  BuildContext context,
  String operationId,
) async {
  Map<String, dynamic>? diagnostic;
  try {
    diagnostic = await SyncRepository().operationDiagnostic(operationId);
  } catch (_) {
    diagnostic = null;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Diagnostic de la sauvegarde'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: SelectableText(
            diagnostic == null
                ? 'Diagnostic indisponible. La sauvegarde locale est conservée.'
                : const JsonEncoder.withIndent('  ').convert(diagnostic),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Fermer'),
        ),
      ],
    ),
  );
}
