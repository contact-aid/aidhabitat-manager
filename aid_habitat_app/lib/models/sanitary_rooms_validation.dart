import 'types.dart';

bool hasBathroomAndWc(Housing housing) {
  final rooms = <String>[
    if (housing.basement) ...housing.basementRooms,
    if (housing.rdc) ...housing.rdcRooms,
    if (housing.floor) ...housing.floorRooms,
    if (housing.secondFloor) ...housing.secondFloorRooms,
    if (housing.thirdFloor) ...housing.thirdFloorRooms,
  ].map((room) => room.toLowerCase().trim());
  return rooms.any((room) => room.contains('salle de bain')) &&
      rooms.any((room) => room.contains('wc'));
}
