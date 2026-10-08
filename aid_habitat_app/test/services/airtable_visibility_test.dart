import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/airtable_visibility_service.dart';

void main() {
  test(
    'a removed Airtable dossier is hidden without deleting its local id',
    () {
      final local = ['airtable:recRemoved', 'airtable:recActive', 'manual-1'];
      final hidden = reconcileHiddenAirtableIds(
        previouslyHidden: const <String>{},
        localDossierIds: local,
        activeDossierIds: const ['airtable:recActive'],
      );
      expect(hidden, {'airtable:recRemoved'});
      expect(local, contains('airtable:recRemoved'));
    },
  );

  test('a restored Airtable dossier is visible again', () {
    final hidden = reconcileHiddenAirtableIds(
      previouslyHidden: const {'airtable:recRestored', 'airtable:recOld'},
      localDossierIds: const ['airtable:recRestored'],
      activeDossierIds: const ['airtable:recRestored'],
    );
    expect(hidden, {'airtable:recOld'});
  });
}
