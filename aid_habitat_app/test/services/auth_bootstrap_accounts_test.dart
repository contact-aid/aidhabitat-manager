import 'package:aid_habitat_app/services/auth_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a fresh local database exposes every production account', () {
    expect(
      AuthService.bootstrapAccountEmails,
      containsAll(<String>[
        'contact@aidhabitat.fr',
        'c.demenais@aidhabitat.fr',
        'c.jeuland@aidhabitat.fr',
        'f.cribier@aidhabitat.fr',
        'r.lamour@aidhabitat.fr',
        'ag.rozec@aidhabitat.fr',
      ]),
    );
    expect(AuthService.bootstrapAccountEmails.toSet(), hasLength(6));
  });
}
