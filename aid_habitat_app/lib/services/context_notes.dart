import 'dart:convert';

const environmentTextTabKey = 'Bénéficiaire-Notes';
const habitsTextTabKey = 'Contexte de vie-Habitudes';
const medicalDrawingTabKey = 'Contexte de vie-Médical';
const autonomyDrawingTabKey = 'Contexte de vie-Autonomie';
const contextTextInitializedKey = 'contextTextV2Initialized';

bool isContextTextTab(String key) =>
    key == environmentTextTabKey || key == habitsTextTabKey;

/// Read-only projection of historical prose. Drawings and original rows stay
/// intact. Once edited, the canonical text (including an explicit clear) wins.
String projectContextText(
  String tabKey,
  String? raw,
  List<Map<String, dynamic>> pages,
) {
  final base = raw == null || raw.trim().isEmpty
      ? <String, dynamic>{'version': 1, 'strokes': []}
      : jsonDecode(raw) as Map<String, dynamic>;
  if (base[contextTextInitializedKey] == true) return jsonEncode(base);
  final sources = tabKey == environmentTextTabKey
      ? (pages.any(
              (p) => p['tabKey'] == medicalDrawingTabKey && _hasContextText(p),
            )
            ? [medicalDrawingTabKey]
            : [environmentTextTabKey])
      : [autonomyDrawingTabKey];
  final texts = <String>[];
  final seen = <String>{};
  for (final key in sources) {
    final ordered = pages.where((p) => p['tabKey'] == key).toList()
      ..sort(
        (a, b) => (a['pageNumber'] as int).compareTo(b['pageNumber'] as int),
      );
    for (final page in ordered) {
      Map<String, dynamic> drawing = {};
      try {
        drawing =
            jsonDecode(page['drawingJson'] as String? ?? '{}')
                as Map<String, dynamic>;
      } catch (_) {}
      if (drawing['deleted'] == true) continue;
      final text =
          drawing['text'] is String &&
              ((drawing['text'] as String).trim().isNotEmpty ||
                  drawing['noteTextInitialized'] == true)
          ? drawing['text']?.toString() ?? ''
          : page['textContent']?.toString() ?? '';
      final normalized = text
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ')
          .toLowerCase();
      if (normalized.isNotEmpty && seen.add(normalized)) texts.add(text.trim());
    }
  }
  return jsonEncode({
    ...base,
    'text': texts.join('\n\n'),
    'noteTextInitialized': true,
  });
}

bool _hasContextText(Map<String, dynamic> page) {
  final drawing =
      jsonDecode(page['drawingJson'] as String? ?? '{}')
          as Map<String, dynamic>;
  if (drawing['deleted'] == true) return false;
  final text =
      drawing['noteTextInitialized'] == true && drawing['text'] is String
      ? drawing['text'] as String
      : (drawing['text'] is String &&
                (drawing['text'] as String).trim().isNotEmpty
            ? drawing['text'] as String
            : page['textContent'] as String? ?? '');
  return text.trim().isNotEmpty;
}
