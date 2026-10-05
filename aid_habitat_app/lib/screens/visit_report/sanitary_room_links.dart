import '../../models/housing_rooms.dart';

const sanitaryRoomFields = <String, String>{
  'basement': 'basement_rooms_json',
  'rdc': 'rdc_rooms_json',
  'floor': 'floor_rooms_json',
  'second_floor': 'second_floor_rooms_json',
  'third_floor': 'third_floor_rooms_json',
};

String canonicalSanitaryLevel(String level) => switch (level) {
  'secondFloor' => 'second_floor',
  'thirdFloor' => 'third_floor',
  _ => level,
};

Map<String, List<HousingRoom>> sanitaryHousingRooms(
  Map<String, dynamic>? row,
) => {
  for (final entry in sanitaryRoomFields.entries)
    entry.key: parseHousingRooms(row?[entry.value] as String?, entry.key),
};

/// Explicit links win. Legacy ordinal association is allowed only when the
/// remaining lists have equal counts; ambiguity never authorizes removal.
Map<String, String> sanitaryRoomLinks({
  required Map<String, List<HousingRoom>> roomsByLevel,
  required String target,
  required Iterable<Map<String, dynamic>> diagnostics,
}) {
  final rows = diagnostics.toList();
  final links = <String, String>{};
  final used = <String>{};
  for (final row in rows) {
    final linked = row['housingRoomId'] as String? ?? '';
    if (linked.isNotEmpty) {
      links[row['id'] as String] = linked;
      used.add(linked);
    }
  }
  for (final entry in roomsByLevel.entries) {
    final level = canonicalSanitaryLevel(entry.key);
    final unlinked = rows
        .where(
          (row) =>
              !links.containsKey(row['id']) &&
              canonicalSanitaryLevel(row['levelField'] as String) == level,
        )
        .toList();
    final candidates = entry.value
        .where(
          (room) =>
              room.label.toLowerCase() == target.toLowerCase() &&
              !used.contains(room.id),
        )
        .toList();
    if (unlinked.length != candidates.length) continue;
    for (var i = 0; i < unlinked.length; i++) {
      links[unlinked[i]['id'] as String] = candidates[i].id;
      used.add(candidates[i].id);
    }
  }
  return links;
}

String sanitaryLevelLabel(String level) =>
    const {
      'basement': 'Sous-sol',
      'rdc': 'RDC',
      'floor': '1er étage',
      'second_floor': '2e étage',
      'third_floor': '3e étage',
    }[canonicalSanitaryLevel(level)] ??
    level;
