import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/screens/dossier_refresh_preview_dialog.dart';

void main() {
  testWidgets(
    'cancel keeps originals and validation excludes unchecked dossiers',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<String>? result;
      const preview = <String, dynamic>{
        'items': [
          {
            'id': 'recAAAAAAAAAAAAAA',
            'name': 'Camille Fictif',
            'profile': 'Coralie',
            'kind': 'create',
            'fields': {
              'dossier': {'visit_date': '2026-09-29'},
              'note': 'Texte dossier fictif',
              'noteBeneficiaire': 'Texte bénéficiaire fictif',
            },
          },
          {
            'id': 'recBBBBBBBBBBBBBB',
            'name': 'Alex Exemple',
            'profile': 'Fabien',
            'kind': 'update',
            'previousOwner': 'Christelle',
            'fields': {
              'dossier': {'ergo_id': 'Fabien'},
            },
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDossierRefreshPreviewDialog(
                    context,
                    preview,
                  );
                },
                child: const Text('Actualiser'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Actualiser'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Réattribution : Christelle → Fabien'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Note du dossier : Texte dossier fictif'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Note Bénéficiaire : Texte bénéficiaire fictif'),
        findsOneWidget,
      );
      await tester.tap(find.text('Conserver l’original'));
      await tester.pumpAndSettle();
      expect(result, isNull);

      await tester.tap(find.text('Actualiser'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Alex Exemple'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider 1 dossier'));
      await tester.pumpAndSettle();
      expect(result, ['recAAAAAAAAAAAAAA']);
    },
  );
}
