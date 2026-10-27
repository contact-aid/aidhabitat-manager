import 'dart:async';
import 'dart:convert';

const visitAiMetadataKey = 'visitAiInsertions';

String appendVisitParagraph(String original, String addition) =>
    addition.trim().isEmpty
    ? original
    : '$original${original.isEmpty ? '' : '\n\n'}${addition.trim()}';

Map<String, dynamic> visitAiInsertions(Map<String, dynamic> drawing) =>
    Map<String, dynamic>.from(drawing[visitAiMetadataKey] as Map? ?? {});

/// A stale editor snapshot can precede an automatic insertion. Carry forward
/// any insertion it has not seen. Once the editor knows the receipt, its own
/// changes (including deleting the generated prose) are preserved verbatim.
String preserveUnseenVisitInsertions(String incoming, String? stored) {
  if (stored == null || !stored.contains(visitAiMetadataKey)) return incoming;
  final drawing = incoming.trim().isEmpty
      ? <String, dynamic>{'text': '', 'strokes': []}
      : jsonDecode(incoming) as Map<String, dynamic>;
  final previous = jsonDecode(stored) as Map<String, dynamic>;
  final known = visitAiInsertions(drawing);
  for (final entry in visitAiInsertions(previous).entries) {
    if (known.containsKey(entry.key)) continue;
    drawing['text'] = appendVisitParagraph(
      drawing['text']?.toString() ?? '',
      entry.value.toString(),
    );
    known[entry.key] = entry.value;
  }
  if (known.isNotEmpty) drawing[visitAiMetadataKey] = known;
  return jsonEncode(drawing);
}

class VisitNoteInsertion {
  const VisitNoteInsertion(
    this.patientId,
    this.tabKey,
    this.receipt,
    this.text,
  );
  final String patientId;
  final String tabKey;
  final String receipt;
  final String text;
}

class VisitNoteEvents {
  static final _events = StreamController<VisitNoteInsertion>.broadcast(
    sync: true,
  );
  static Stream<VisitNoteInsertion> get stream => _events.stream;
  static void emit(VisitNoteInsertion insertion) => _events.add(insertion);
}
