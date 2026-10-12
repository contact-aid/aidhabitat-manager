import 'dart:convert';
import 'dart:math';

class HousingRoom {
  const HousingRoom({required this.id, required this.label});
  final String id;
  final String label;
  factory HousingRoom.fromJson(Map<String, dynamic> json) =>
      HousingRoom(id: json['id'] as String, label: json['label'] as String);
  Map<String, dynamic> toJson() => {'id': id, 'label': label};
}

/// Legacy IDs are deterministic across devices and stay in memory on reads.
/// An explicit edit persists them; new occurrences must receive a new UUID.
List<HousingRoom> parseHousingRooms(String? raw, String level) {
  level = switch (level) {
    'second_floor' => 'secondFloor',
    'third_floor' => 'thirdFloor',
    _ => level,
  };
  if (raw == null || raw.trim().isEmpty) return const [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) throw const FormatException('Liste de pièces invalide');
  final seen = <String>{};
  return List.generate(decoded.length, (index) {
    final value = decoded[index];
    final room = value is String
        ? HousingRoom(id: 'legacy:$level:$index', label: value)
        : HousingRoom.fromJson((value as Map).cast<String, dynamic>());
    if (room.id.isEmpty || !seen.add(room.id)) {
      throw const FormatException('Identité de pièce absente ou en doublon');
    }
    return room;
  });
}

HousingRoom createHousingRoom(String label) {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final id =
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  return HousingRoom(id: id, label: label);
}
