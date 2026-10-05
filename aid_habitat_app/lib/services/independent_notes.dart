import 'dart:convert';

/// Persisted in drawing_json, understood by the server without a schema change.
/// Build 64 ignores this property; the server also adds it on legacy saves.
String stampNoteTextInitialization(
  String tabKey,
  int page,
  String drawingJson,
) {
  if (page != 0 ||
      (tabKey != 'notes_rapides' && tabKey != 'Bénéficiaire-Notes')) {
    return drawingJson;
  }
  final drawing = jsonDecode(drawingJson) as Map<String, dynamic>;
  return jsonEncode({...drawing, 'noteTextInitialized': true});
}
