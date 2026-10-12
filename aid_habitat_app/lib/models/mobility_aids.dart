/// Display/edit tokens only. Reading a record never normalizes stored text.
List<String> parseMobilityAids(String raw) {
  final seen = <String>{};
  return raw
      .split(RegExp(r'[,;\n\r]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty && seen.add(value.toLowerCase()))
      .toList();
}

/// Call only after a deliberate selection edit; unknown tokens remain choices.
String encodeMobilityAids(Iterable<String> values) =>
    parseMobilityAids(values.join(', ')).join(', ');
