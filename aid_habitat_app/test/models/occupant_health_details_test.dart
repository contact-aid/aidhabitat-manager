import 'package:aid_habitat_app/models/types.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'health details and fiscal year survive offline JSON and unrelated edits',
    () {
      const occupant = Occupant(
        apa: true,
        apaGir: '4',
        apaDetails: 'Évaluation APA',
        invalidity: true,
        invalidityTxt: '80%',
        invalidityDetails: 'Décision MDPH',
        fiscalReferenceYear: '2025',
      );
      final restored = Occupant.fromJson(
        occupant.toJson(),
      ).copyWith(firstName: 'Anne');
      expect(restored.apaDetails, 'Évaluation APA');
      expect(restored.invalidityDetails, 'Décision MDPH');
      expect(restored.fiscalReferenceYear, '2025');
      expect(
        restored
            .copyWith(
              apaDetails: '',
              invalidityDetails: '',
              fiscalReferenceYear: '',
            )
            .toJson(),
        containsPair('fiscalReferenceYear', ''),
      );
      expect(Occupant.fromJson({'firstName': 'Ancien'}).apaDetails, '');
    },
  );
}
