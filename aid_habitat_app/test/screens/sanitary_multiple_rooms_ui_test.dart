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
    testWidgets(
      '${bathroom ? "Bathroom" : "WC"} edits the chosen identity and preserves unmatched legacy rooms',
      (tester) async {
        final repo = _MemoryRepository()
          ..stored = _fixture(['rdc', 'rdc', 'floor']);
        // The old third room has no matching housing entry: opening must keep it.
        repo.housing['rdc_rooms_json'] =
            '["Salle de bain","WC","Salle de bain","WC"]';
        final bath = BathroomTabController();
        final wc = WcTabController();
        Widget screen() => MaterialApp(
          home: Scaffold(
            body: bathroom
                ? BathroomTab(
                    dossier: _dossier,
                    repository: repo,
                    controller: bath,
                  )
                : WcTab(dossier: _dossier, repository: repo, controller: wc),
          ),
        );
        Future<void> flush() =>
            bathroom ? bath.flushPendingSave() : wc.flushPendingSave();
        await tester.binding.setSurfaceSize(const Size(1100, 1200));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(repo.writes, 0);
        final firstSnapshot = bathroom
            ? repo.stored.sdbInstances.first.toJson()
            : repo.stored.wcInstances.first.toJson();
        final orphanSnapshot = bathroom
            ? repo.stored.sdbInstances.last.toJson()
            : repo.stored.wcInstances.last.toJson();
        await tester.tap(
          find.text(
            bathroom ? 'Original 1 · Salle de bain 2' : 'Original 1 · WC 2',
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(bathroom ? 'Douche' : 'Trop basse').first);
        await tester.pump();
        // Switch before the debounce. The previous room still owns its mutation.
        await tester.tap(
          find.text(
            bathroom ? 'Original 0 · Salle de bain 1' : 'Original 0 · WC 1',
          ),
        );
        await tester.pump();
        await flush();
        expect(
          bathroom
              ? repo.stored.sdbInstances.length
              : repo.stored.wcInstances.length,
          3,
        );
        expect(
          bathroom
              ? repo.stored.sdbInstances.first.toJson()
              : repo.stored.wcInstances.first.toJson(),
          firstSnapshot,
        );
        expect(
          bathroom
              ? repo.stored.sdbInstances.last.toJson()
              : repo.stored.wcInstances.last.toJson(),
          orphanSnapshot,
        );
        expect(
          bathroom
              ? repo.stored.sdbInstances[1].sdbBacDouche
              : repo.stored.wcInstances[1].wcCuvetteTropBasse,
          true,
        );
        expect(
          bathroom
              ? repo.stored.sdbInstances[1].housingRoomId
              : repo.stored.wcInstances[1].housingRoomId,
          isNotEmpty,
        );
        final saved = jsonEncode(repo.stored.toJson());
        await tester.pumpWidget(const SizedBox());
        repo.online = true;
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        await flush();
        expect(jsonEncode(repo.stored.toJson()), saved);
      },
    );
  }
}
