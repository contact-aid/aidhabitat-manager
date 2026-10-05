// Characterization tests: passing proves the documented build-64 limitation,
// NOT that multiple rooms are safe to release. Run with tool/test_build64_sanitary.sh.
import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/bathroom_tab.dart';
import 'package:aid_habitat_app/screens/visit_report/wc_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryRepository extends Fake implements DossierRepository {
  late DiagnosticSanitaire stored;
  Map<String, dynamic> housing = {};
  int writes = 0;
  bool online = false;

  @override
  Future<DiagnosticSanitaire?> fetchDiagnosticSanitaire(String id) async =>
      DiagnosticSanitaire(
        dossierId: id,
        sdbInstances: stored.sdbInstances
            .map(
              (r) => BathroomInstance.fromJson(
                jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
              ),
            )
            .toList(),
        wcInstances: stored.wcInstances
            .map(
              (r) => WcInstance.fromJson(
                jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>,
              ),
            )
            .toList(),
      );
  @override
  Future<Map<String, dynamic>?> fetchHousingRaw(String id) async => housing;
  @override
  Future<bool> refreshDiagnosticSanitaireFromRemote(String id) async {
    if (!online) throw StateError('Synthetic offline');
    return false;
  }

  @override
  Future<void> upsertDiagnosticSanitaire(
    String id,
    DiagnosticSanitaire value,
  ) async {
    stored = value;
    writes++;
  }
}

final _dossier = Dossier(
  id: 'synthetic-sanitary-dossier',
  patient: Patient(
    id: 'synthetic-patient',
    firstName: 'Fictif',
    lastName: 'Test',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.IN_PROGRESS,
  ergoId: '',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.OTHER,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: const {},
  createdAt: '',
);

DiagnosticSanitaire _fixture(List<String> levels) => DiagnosticSanitaire(
  dossierId: _dossier.id,
  sdbInstances: [
    for (var i = 0; i < levels.length; i++)
      BathroomInstance(
        id: 'bath-$i',
        levelField: levels[i],
        levelLabel: 'Original $i',
        sdbBaignoire: true,
        sdbBaignoireHauteur: 40 + i.toDouble(),
        porteSdbDimension: 70 + i.toDouble(),
      ),
  ],
  wcInstances: [
    for (var i = 0; i < levels.length; i++)
      WcInstance(
        id: 'wc-$i',
        levelField: levels[i],
        levelLabel: 'Original $i',
        wcCuvetteHauteur: 45 + i.toDouble(),
        porteWcDimension: 80 + i.toDouble(),
        observationEquipementsUtilisation: 'Observation fictive $i',
      ),
  ],
);

void main() {
  for (final bathroom in [true, false]) {
    final kind = bathroom ? 'Bathroom' : 'WC';
    for (final levels in [
      <String>['rdc'],
      ['rdc', 'rdc'],
      ['rdc', 'floor'],
    ]) {
      testWidgets('$kind build64 load/save/reopen ${levels.join("+")}', (
        tester,
      ) async {
        final repo = _MemoryRepository()..stored = _fixture(levels);
        for (final level in levels.toSet()) {
          repo.housing['${level}_rooms_json'] = jsonEncode([
            for (final l in levels)
              if (l == level) ...['Salle de bain', 'WC'],
          ]);
        }
        final bathController = BathroomTabController();
        final wcController = WcTabController();
        Widget screen() => MaterialApp(
          home: Scaffold(
            body: bathroom
                ? BathroomTab(
                    dossier: _dossier,
                    repository: repo,
                    controller: bathController,
                  )
                : WcTab(
                    dossier: _dossier,
                    repository: repo,
                    controller: wcController,
                  ),
          ),
        );
        Future<void> flush() => bathroom
            ? bathController.flushPendingSave()
            : wcController.flushPendingSave();
        List<String> ids() => bathroom
            ? repo.stored.sdbInstances.map((r) => r.id).toList()
            : repo.stored.wcInstances.map((r) => r.id).toList();
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        await flush();
        expect(
          repo.writes,
          0,
          reason: 'Opening alone must not persist changes',
        );
        expect(ids().length, levels.length);
        // Quick selection changes before the debounced write.
        if (levels.contains('floor')) {
          if (bathroom) {
            bathController.selectLevelField('floor');
            bathController.selectLevelField('rdc');
          } else {
            wcController.selectLevelField('floor');
            wcController.selectLevelField('rdc');
          }
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(bathroom ? 'Douche' : 'Trop basse').first);
        await tester.pump();
        await flush();
        final expectedCount = levels.toSet().length;
        expect(
          ids().length,
          expectedCount,
          reason:
              'KNOWN BLOCKER: build64 drops the second room at the same level',
        );
        expect(ids().first, bathroom ? 'bath-0' : 'wc-0');
        expect(
          bathroom
              ? repo.stored.wcInstances.length
              : repo.stored.sdbInstances.length,
          levels.length,
          reason: 'The other sanitary type is preserved',
        );
        if (bathroom) {
          expect(repo.stored.sdbInstances.first.sdbBaignoireHauteur, 40);
          expect(repo.stored.sdbInstances.first.sdbBacDouche, true);
        } else {
          expect(repo.stored.wcInstances.first.wcCuvetteHauteur, 45);
          expect(
            repo.stored.wcInstances.first.observationEquipementsUtilisation,
            'Observation fictive 0',
          );
        }
        final savedIds = ids();
        await tester.pumpWidget(const SizedBox());
        repo.online =
            true; // Reopen after reconnection; no external network is used.
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(ids(), savedIds);
        await tester.tap(find.text(bathroom ? 'Douche' : 'Trop haute').first);
        await tester.pump();
        await flush();
        expect(ids(), savedIds);
      });
    }
  }
}
