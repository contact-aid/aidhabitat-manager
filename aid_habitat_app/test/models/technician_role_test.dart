import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/models/types.dart';

void main() {
  test('professional roles keep distinct API values and labels', () {
    expect(LocalUserRole.technician.apiValue, 'TECHNICIAN');
    expect(LocalUserRole.technician.label, 'Technicien');
    expect(LocalUserRole.ergo.apiValue, 'ERGO');
    expect(LocalUserRole.admin.apiValue, 'ADMIN');
  });
}
