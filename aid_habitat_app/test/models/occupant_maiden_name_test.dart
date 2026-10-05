import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maiden name survives occupant JSON and unrelated edits', () {
    const original = Occupant(
      firstName: 'Madeleine',
      lastName: 'Exemple',
      gender: 'Femme',
      maidenName: 'Martin',
    );

    final restored = Occupant.fromJson(original.toJson());
    expect(restored.maidenName, 'Martin');
    expect(restored.copyWith(birthDate: '1948-01-01').maidenName, 'Martin');
    expect(restored.copyWith(maidenName: '').toJson()['maidenName'], '');
  });

  test('legacy occupants keep the maiden name absent until it is entered', () {
    final legacy = Occupant.fromJson({
      'firstName': 'Camille',
      'lastName': 'Exemple',
      'gender': 'Femme',
    });
    expect(legacy.maidenName, isNull);
    expect(
      legacy.copyWith(birthDate: '1950-01-01').toJson(),
      isNot(contains('maidenName')),
    );
  });
}
