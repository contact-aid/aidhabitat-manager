import 'dart:convert';

const sanitaryTextTabKey = 'Sanitaires-Notes';
const bathroomDrawingTabKey = 'Sanitaires-Salle de bain-Manuscrit';
const wcDrawingTabKey = 'Sanitaires-WC-Manuscrit';

bool isSanitaryDrawingTab(String tabKey) =>
    tabKey == bathroomDrawingTabKey || tabKey == wcDrawingTabKey;

/// Existing shared drawings remain readable until each room edits its own copy.
/// Reading never writes, and an explicit blank or tombstone always wins.
String? sanitaryLegacyDrawing(String? json) {
  if (json == null || json.isEmpty) return null;
  try {
    final drawing = jsonDecode(json) as Map<String, dynamic>;
    return jsonEncode({...drawing, 'text': ''});
  } catch (_) {
    return null;
  }
}
