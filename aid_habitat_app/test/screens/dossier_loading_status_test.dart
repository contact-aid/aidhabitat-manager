import 'package:aid_habitat_app/components/dossier_loading_status.dart';
import 'package:aid_habitat_app/models/dossier_refresh_phase.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cached dossiers remain visible during refresh and failure', () {
    for (final phase in DossierRefreshPhase.values) {
      expect(
        needsDossierLoadingStatus(hasDossiers: true, phase: phase),
        isFalse,
      );
    }
  });
  test('empty cache is not a confirmed empty remote list', () {
    expect(
      needsDossierLoadingStatus(
        hasDossiers: false,
        phase: DossierRefreshPhase.loading,
      ),
      isTrue,
    );
    expect(
      needsDossierLoadingStatus(
        hasDossiers: false,
        phase: DossierRefreshPhase.failed,
      ),
      isTrue,
    );
    expect(
      needsDossierLoadingStatus(
        hasDossiers: false,
        phase: DossierRefreshPhase.ready,
      ),
      isFalse,
    );
  });
  for (final offline in [false, true]) {
    for (final failed in [false, true]) {
      testWidgets('empty cache feedback offline=$offline failed=$failed', (
        tester,
      ) async {
        var retries = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DossierLoadingStatus(
                offline: offline,
                failed: failed,
                onRetry: () => retries++,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 6));
        expect(find.text('Aucun dossier'), findsNothing);
        expect(
          find.byType(CircularProgressIndicator),
          !offline && !failed ? findsOneWidget : findsNothing,
        );
        await tester.tap(find.text('Réessayer'));
        expect(retries, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
