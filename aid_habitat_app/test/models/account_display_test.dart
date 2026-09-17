import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/models/types.dart';

void main() {
  test('short display keeps full assignment identity intact', () {
    const user = LocalAppUser(
      id: 'technician',
      email: 'ag.rozec@aidhabitat.fr',
      displayName: 'Anne-Gaëlle ROZEC',
      role: LocalUserRole.technician,
    );
    expect(user.shortDisplayName, 'Anne-Gaëlle');
    expect(user.displayName, 'Anne-Gaëlle ROZEC');
  });
  test('legacy admin label is branded without renaming the technician', () {
    const admin = LocalAppUser(
      id: 'admin',
      email: 'contact@aidhabitat.fr',
      displayName: 'Renan',
      role: LocalUserRole.admin,
    );
    expect(admin.shortDisplayName, "Aid'habitat");
    expect(
      admin
          .copyWith(
            email: 'r.lamour@aidhabitat.fr',
            role: LocalUserRole.technician,
            displayName: 'Renan LAMOUR',
          )
          .shortDisplayName,
      'Renan',
    );
    expect(LocalUserRole.ergo.label, 'Ergothérapeute');
  });
}
