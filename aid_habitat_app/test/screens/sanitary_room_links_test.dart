import 'package:aid_habitat_app/models/housing_rooms.dart';
import 'package:aid_habitat_app/screens/visit_report/sanitary_room_links.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('upper floors use the same stable IDs across API and SQLite keys', () {
    for (final level in ['second', 'third']) {
      final snake = '${level}_floor';
      final camel = '${level}Floor';
      final fromSqlite = parseHousingRooms('["WC"]', snake);
      final fromApi = parseHousingRooms('["WC"]', camel);
      expect(fromSqlite.single.id, fromApi.single.id);
      final links = sanitaryRoomLinks(
        roomsByLevel: {snake: fromSqlite},
        target: 'WC',
        diagnostics: [
          {'id': 'old-toilet', 'levelField': camel},
        ],
      );
      expect(links, {'old-toilet': fromApi.single.id});
    }
  });
  test('different counts cannot authorize ordinal association or deletion', () {
    final rooms = parseHousingRooms('["Salle de bain"]', 'rdc');
    final links = sanitaryRoomLinks(
      roomsByLevel: {'rdc': rooms},
      target: 'Salle de bain',
      diagnostics: [
        {'id': 'first', 'levelField': 'rdc'},
        {'id': 'second', 'levelField': 'rdc'},
      ],
    );
    expect(links, isEmpty);
  });
  test(
    'an explicit link wins while unmatched historical rooms remain unlinked',
    () {
      final links = sanitaryRoomLinks(
        roomsByLevel: {
          'rdc': const [HousingRoom(id: 'room-a', label: 'WC')],
        },
        target: 'WC',
        diagnostics: [
          {'id': 'first', 'levelField': 'rdc', 'housingRoomId': 'room-a'},
          {'id': 'orphan', 'levelField': 'rdc'},
        ],
      );
      expect(links, {'first': 'room-a'});
    },
  );
  test(
    'malformed legacy lists are rejected, never interpreted as deletion',
    () {
      expect(
        () => sanitaryHousingRooms({'rdc_rooms_json': '{broken'}),
        throwsFormatException,
      );
    },
  );
}
