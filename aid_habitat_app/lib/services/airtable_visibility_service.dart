import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Set<String> reconcileHiddenAirtableIds({
  required Iterable<String> previouslyHidden,
  required Iterable<String> localDossierIds,
  required Iterable<String> activeDossierIds,
}) {
  final active = activeDossierIds.toSet();
  return <String>{
    ...previouslyHidden.where((id) => !active.contains(id)),
    ...localDossierIds.where(
      (id) => id.startsWith('airtable:') && !active.contains(id),
    ),
  };
}

/// Keeps Airtable removals out of the dossier list while retaining every
/// dossier and its visit data in the local and remote databases.
class AirtableVisibilityService {
  AirtableVisibilityService._();

  static final instance = AirtableVisibilityService._();
  static const _storage = FlutterSecureStorage();
  final Map<String, Set<String>> _hiddenByUser = {};

  String _key(String email) =>
      'aidhabitat.airtable_hidden.${email.trim().toLowerCase()}';

  Future<void> load(String email) async {
    final key = _key(email);
    try {
      final raw = await _storage.read(key: key);
      final decoded = jsonDecode(raw ?? '[]');
      _hiddenByUser[key] = decoded is List
          ? decoded
                .whereType<String>()
                .where((id) => id.startsWith('airtable:'))
                .toSet()
          : <String>{};
    } catch (_) {
      _hiddenByUser.putIfAbsent(key, () => <String>{});
    }
  }

  bool isHidden(String email, String dossierId) =>
      _hiddenByUser[_key(email)]?.contains(dossierId) ?? false;

  Future<void> reconcile({
    required String email,
    required Iterable<String> localDossierIds,
    required Iterable<String> activeDossierIds,
  }) async {
    final key = _key(email);
    final hidden = reconcileHiddenAirtableIds(
      previouslyHidden: _hiddenByUser[key] ?? const <String>{},
      localDossierIds: localDossierIds,
      activeDossierIds: activeDossierIds,
    );
    _hiddenByUser[key] = hidden;
    try {
      await _storage.write(
        key: key,
        value: jsonEncode(hidden.toList()..sort()),
      );
    } catch (_) {
      // The current session still hides removed dossiers; the next successful
      // Airtable read will restore the same visibility if storage is locked.
    }
  }
}
