import 'dart:async';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/conflict_resolution_screen.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late Dossier dossier;
  late List<SyncConflictReview> reviews;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    final local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    final repository = DossierRepository(database: local);
    final queue = SyncRepository.forTesting(database: local);
    final remote = <String, dynamic>{
      'id': 'dossier-1',
      'updatedAt': '2026-09-01T10:00:00Z',
      'patient': {
        'id': 'patient-1',
        'firstName': 'Version serveur',
        'lastName': 'Exemple',
        'updatedAt': '2026-09-01T10:00:00Z',
      },
      'housing': {'updatedAt': '2026-09-01T10:00:00Z'},
    };
    await repository.mergeRemoteDossierPayloads([remote]);
    await repository.updatePatient('patient-1', {
      'first_name': 'Ma nouvelle saisie',
    });
    final op = (await queue.fetchRunnableOperations()).single;
    await queue.tryMarkRunning(op);
    await queue.markConflict(
      operationId: op.id,
      entityType: op.entityType,
      entityLocalId: op.entityLocalId,
      expectedPayloadJson: op.payloadJson,
      error: 'synthetic',
    );
    dossier = (await repository.fetchDossierById('dossier-1'))!;
    reviews = await repository.reviewConflicts('dossier-1', remote);
  });
  tearDown(() async => db.close());

  for (final width in [390.0, 1024.0]) {
    testWidgets(
      'review fits width $width and submits only one explicit choice',
      (tester) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final done = Completer<void>();
        final choices = <bool>[];
        var resolved = false;
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: const ValueKey('review'),
              child: ConflictResolutionScreen(
                localDossier: dossier,
                onResolved: () {
                  resolved = true;
                },
                loadReviews: () async => [...reviews],
                resolveReview: (review, keepLocal) async {
                  choices.add(keepLocal);
                  await done.future;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Ma nouvelle saisie'), findsOneWidget);
        expect(find.text('Version serveur'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await expectLater(
          find.byKey(const ValueKey('review')),
          matchesGoldenFile('goldens/conflict_review_${width.toInt()}.png'),
        );
        await tester.tap(find.text('Conserver mes changements'));
        await tester.pump();
        expect(choices, [true]);
        expect(resolved, isFalse);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(
                  OutlinedButton,
                  'Prendre ces valeurs du serveur',
                ),
              )
              .onPressed,
          isNull,
        );
        done.complete();
        await tester.pumpAndSettle();
        expect(resolved, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'offline comparison preserves the screen and offers refresh without writing',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ConflictResolutionScreen(
            localDossier: dossier,
            onResolved: () => fail('not resolved'),
            loadReviews: () async {
              calls++;
              throw StateError('offline');
            },
            resolveReview: (_, _) async => fail('no write allowed'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Vos modifications restent'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      await tester.tap(find.byTooltip('Actualiser'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed decision does not close the screen or allow stale retries',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ConflictResolutionScreen(
            localDossier: dossier,
            onResolved: () => fail('not resolved'),
            loadReviews: () async => [...reviews],
            resolveReview: (_, _) async =>
                throw StateError('edited during review'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prendre ces valeurs du serveur'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Choix non applique'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Conserver mes changements'),
            )
            .onPressed,
        isNull,
      );
    },
  );
}
