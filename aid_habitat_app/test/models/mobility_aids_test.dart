import 'package:aid_habitat_app/models/mobility_aids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'single, multiple and unknown aid labels survive explicit selection edits',
    () {
      expect(parseMobilityAids('Canne'), ['Canne']);
      final values = parseMobilityAids(
        'Canne; Orthèse spéciale\nDéambulateur, canne',
      );
      expect(values, ['Canne', 'Orthèse spéciale', 'Déambulateur']);
      expect(
        encodeMobilityAids(values.where((e) => e != 'Canne')),
        'Orthèse spéciale, Déambulateur',
      );
      expect(encodeMobilityAids([]), '');
      expect(parseMobilityAids(''), isEmpty);
    },
  );
}
