import '../../models/housing_rooms.dart';

const sanitaryRoomFields = <String, String>{
  'basement': 'basement_rooms_json',
  'rdc': 'rdc_rooms_json',
  'floor': 'floor_rooms_json',
  'second_floor': 'second_floor_rooms_json',
  'third_floor': 'third_floor_rooms_json',
};

Map<String, List<HousingRoom>> sanitaryHousingRooms(
  Map<String, dynamic>? row,
) => {
  for (final entry in sanitaryRoomFields.entries)
    entry.key: parseHousingRooms(row?[entry.value] as String?, entry.key),
};

/// Resolve old ordinal associations without mutating or discarding a record.
/// Explicit links always win; unlinked historical rooms keep their stored order.
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
  for (final row in rows) {
    final id = row['id'] as String;
    if (links.containsKey(id)) continue;
    for (final room
        in roomsByLevel[row['levelField']] ?? const <HousingRoom>[]) {
      if (room.label.toLowerCase() == target.toLowerCase() &&
          !used.contains(room.id)) {
        links[id] = room.id;
        used.add(room.id);
        break;
      }
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
    }[level] ??
    level;
