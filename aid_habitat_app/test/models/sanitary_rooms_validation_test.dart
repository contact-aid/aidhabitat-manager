import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/models/sanitary_rooms_validation.dart';

void main() {
  Housing housing({
    bool rdc = false,
    List<String> rdcRooms = const [],
    bool floor = false,
    List<String> floorRooms = const [],
  }) => Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
    rdc: rdc,
    rdcRooms: rdcRooms,
    floor: floor,
    floorRooms: floorRooms,
  );
  test('bathroom and WC can be on different active levels', () {
    expect(
      hasBathroomAndWc(
        housing(
          rdc: true,
          rdcRooms: ['Salle de bain'],
          floor: true,
          floorRooms: ['WC'],
        ),
      ),
      isTrue,
    );
  });
  test('same level remains valid', () {
    expect(
      hasBathroomAndWc(housing(rdc: true, rdcRooms: [' salle de bain ', 'wc'])),
      isTrue,
    );
  });
  test('inactive levels do not satisfy missing rooms', () {
    expect(
      hasBathroomAndWc(
        housing(
          rdc: true,
          rdcRooms: ['Salle de bain'],
          floor: false,
          floorRooms: ['WC'],
        ),
      ),
      isFalse,
    );
  });
  test('missing bathroom or WC remains incomplete', () {
    for (final rooms in [
      <String>[],
      ['WC'],
      ['Salle de bain'],
    ]) {
      expect(hasBathroomAndWc(housing(rdc: true, rdcRooms: rooms)), isFalse);
    }
  });
}
