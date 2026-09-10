import 'dart:async';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/conflict_resolution_screen.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _id = 'secondary-widget-dossier';
const _version = '2026-09-02T09:00:00.000Z';
const _mesures = 'mesures_anthropometriques';
const _observations = 'observations_synthese';
const _diagnostic = 'diagnostic_sanitaires';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late DossierRepository repository;
  late Dossier dossier;
  late List<SyncConflictReview> reviews;

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    repository = DossierRepository(database: local);
    final queue = SyncRepository.forTesting(database: local);
    await repository.mergeRemoteDossierPayloads([
      {
        'id': _id,
        'updatedAt': _version,
        'patient': {
          'id': 'secondary-patient',
          'firstName': 'Synthetic',
          'lastName': 'Review',
          'updatedAt': _version,
        },
        'housing': {'updatedAt': _version},
      },
    ]);
    final raw = <String, Map<String, dynamic>?>{
      _mesures: {
        'dossierId': _id,
        'updatedAt': _version,
        'deboutHauteurCoude': 91.0,
        'observations': 'Server measure',
      },
      _observations: {
        'dossierId': _id,
        'updatedAt': _version,
        'projetSouhaitUsage': 'Server project',
      },
      _diagnostic: {
        'dossierId': _id,
        'updatedAt': _version,
        'sdbInstances': <dynamic>[],
        'wcInstances': <dynamic>[],
      },
    };
    await repository.mergeRemoteMesuresPayload(_id, raw[_mesures]);
    await repository.mergeRemoteObservationsPayload(_id, raw[_observations]);
    await repository.mergeRemoteDiagnosticSanitairePayload(
      _id,
      raw[_diagnostic],
    );
    await repository.upsertMesures(
      _id,
      const MesuresAnthropometriques(
        dossierId: _id,
        deboutHauteurCoude: 92,
        observations: 'Local measure',
      ),
    );
    await repository.upsertObservations(
      _id,
      const ObservationsSynthese(
        dossierId: _id,
        projetSouhaitUsage: 'Local project',
      ),
    );
    await repository.upsertDiagnosticSanitaire(
      _id,
      DiagnosticSanitaire.fromJson({
        'dossierId': _id,
        'sdbInstances': <dynamic>[],
        'wcInstances': <dynamic>[],
      }),
    );
    for (final op in await queue.fetchRunnableOperations()) {
      expect(await queue.tryMarkRunning(op), isTrue);
      await queue.markConflict(
        operationId: op.id,
        entityType: op.entityType,
        entityLocalId: op.entityLocalId,
        expectedPayloadJson: op.payloadJson,
        error: 'synthetic child conflict',
      );
    }
    dossier = (await repository.fetchDossierById(_id))!;
    reviews = await repository.reviewSecondaryConflicts(_id, raw);
    expect(reviews.map((r) => r.entityType).toSet(), {
      _mesures,
      _observations,
      _diagnostic,
    });
  });
  tearDown(() async => db.close());

  testWidgets(
    'secondary choice double tap and refresh before pump write once',
    (tester) async {
      final gate = Completer<void>();
      final compared = reviews.singleWhere(
        (r) => r.entityType == _observations,
      );
      var calls = 0;
      var loads = 0;
      var resolved = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConflictResolutionScreen(
            localDossier: dossier,
            loadReviews: () async {
              loads++;
              return [compared];
            },
            resolveReview: (review, keepLocal) async {
              calls++;
              expect(keepLocal, isFalse);
              expect(review, same(compared));
              await gate.future;
            },
            onResolved: () {
              resolved++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final choice = find.text('Prendre ces valeurs du serveur');
      await tester.tap(choice);
      await tester.tap(choice);
      await tester.tap(find.text('Conserver mes changements'));
      await tester.tap(find.byTooltip('Actualiser'));
      expect(calls, 1);
      expect(loads, 1, reason: 'No reload may race a pending decision');
      expect(resolved, 0);
      await tester.pump();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Conserver mes changements'),
            )
            .onPressed,
        isNull,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(resolved, 1);
      await tester.runAsync(() async {
        expect(
          await db.query('sync_conflict_history'),
          isEmpty,
          reason: 'The injected resolver owns persistence',
        );
      });
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 1024.0]) {
    for (final entry in <String, List<String>>{
      _mesures: ['Mesures', 'Hauteur du coude debout', 'Observations'],
      _observations: [
        'Observations de synthese',
        "Projet et souhaits de l'usager",
      ],
      _diagnostic: ['Diagnostic sanitaires', 'Salles de bain', 'WC'],
    }.entries) {
      testWidgets('${entry.key} uses field labels and fits width $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.5)),
              child: child!,
            ),
            home: ConflictResolutionScreen(
              localDossier: dossier,
              loadReviews: () async => [
                reviews.singleWhere((r) => r.entityType == entry.key),
              ],
              resolveReview: (_, _) async => fail('Rendering must not resolve'),
              onResolved: () => fail('Rendering must not dismiss'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final label in entry.value) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.text('Cet iPad'), findsWidgets);
        expect(find.text('Serveur'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text('Prendre ces valeurs du serveur'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          expect(await db.query('sync_conflict_history'), isEmpty);
        });
      });
    }
  }
}
