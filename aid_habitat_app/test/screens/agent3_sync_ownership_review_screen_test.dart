import 'dart:async';
import 'package:aid_habitat_app/screens/sync_ownership_review_screen.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
import 'package:aid_habitat_app/services/sync_ownership_self_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
  });
  tearDown(() => db.close());

  Future<void> user(String id, {String role = 'admin'}) async {
    await db.insert('app_users', {
      'local_id': id,
      'email': '$id@example.test',
      'display_name': id,
      'role': role,
      'password_salt': '',
      'password_hash': '',
      'is_active': 1,
      'created_at': '2026-09-10',
      'updated_at': '2026-09-10',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.insert('app_session', {
      'id': 1,
      'user_local_id': id,
      'created_at': '2026-09-10',
      'updated_at': '2026-09-10',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> operation(String id, {String status = 'pending'}) async {
    await db.insert('sync_operations', {
      'id': id,
      'entity_type': 'dossier',
      'entity_local_id': 'local-synthetic',
      'operation_type': 'update',
      'payload_json':
          '{"updates":{"status":"SECRET-VALUE","password":"NEVER-SHOW"}}',
      'status': status,
      'created_at': '2026-09-10T08:00:00.000Z',
      'updated_at': '2026-09-10T08:00:00.000Z',
    });
  }

  Future<void> settle(WidgetTester tester, {bool waitForLoad = true}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    do {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
      if (!waitForLoad || find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        return;
      }
    } while (DateTime.now().isBefore(deadline));
    fail('Ownership review did not finish loading');
  }

  Future<void> screen(
    WidgetTester tester, {
    SyncPayloadOpener? opener,
    VoidCallback? onReviewed,
    bool waitForLoad = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SyncOwnershipReviewScreen(
          database: local,
          openPayload: opener ?? Future.value,
          onReviewed: onReviewed,
        ),
      ),
    );
    await settle(tester, waitForLoad: waitForLoad);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await settle(tester);
  }

  testWidgets(
    'non-admin can confirm own historical work without seeing protected values',
    (tester) async {
      await tester.runAsync(() async {
        await operation('old');
        await user('ergo', role: 'ergo');
        await screen(tester);
        expect(find.byType(Checkbox), findsOneWidget);
        expect(find.text('local-synthetic'), findsNothing);
        expect(find.textContaining('SECRET-VALUE'), findsNothing);
        expect(find.textContaining('Champs concernés'), findsNothing);
        expect(
          (await db.query(
            SyncOperationOwnership.tableName,
          )).single['owner_user_local_id'],
          isNull,
        );
        await confirm(tester);
        expect(await SyncOperationOwnership.mayClaim(db, 'old'), isTrue);
        expect((await db.query('app_users')).single['role'], 'ergo');
        expect(
          (await db.query('sync_operations')).single['payload_json'],
          contains('SECRET-VALUE'),
        );
        expect(
          (await db.query(
            SyncOperationOwnership.historyTableName,
          )).single['reason'],
          contains('explicit_self_confirmation'),
        );
      });
    },
  );
  testWidgets('review identifies the target without exposing payload secrets', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await operation('old');
      await user('admin');
      await screen(tester);
      expect(find.text('local-synthetic'), findsOneWidget);
      expect(find.textContaining('Champs concernés : Status.'), findsOneWidget);
      expect(find.textContaining('SECRET-VALUE'), findsNothing);
      expect(find.textContaining('NEVER-SHOW'), findsNothing);
    });
  });
  testWidgets('admin can explicitly recover missing metadata', (tester) async {
    await tester.runAsync(() async {
      await operation('missing');
      await db.delete(SyncOperationOwnership.tableName);
      await user('admin');
      await screen(tester);
      expect(await db.query(SyncOperationOwnership.tableName), isEmpty);
      await confirm(tester);
      expect(await SyncOperationOwnership.mayClaim(db, 'missing'), isTrue);
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        contains('SECRET-VALUE'),
      );
    });
  });

  testWidgets('confirmation attributes one operation only', (tester) async {
    await tester.runAsync(() async {
      var notifications = 0;
      await operation('old-a');
      await operation('old-b');
      await user('admin');
      await screen(tester, onReviewed: () => notifications++);
      await confirm(tester);
      final rows = await db.query(
        SyncOperationOwnership.tableName,
        orderBy: 'operation_id',
      );
      expect(rows.first['owner_user_local_id'], 'admin');
      expect(rows.last['owner_user_local_id'], isNull);
      expect(notifications, 1);
    });
  });
  testWidgets('changed payload cannot be confirmed from a stale review', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await operation('old');
      await user('admin');
      await screen(tester);
      await db.update('sync_operations', {
        'payload_json': '{"updates":{"status":"NEW"}}',
      });
      await confirm(tester);
      expect(
        find.textContaining('Cette opération a changé pendant la revue'),
        findsOneWidget,
      );
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['owner_user_local_id'],
        isNull,
      );
    });
  });
  testWidgets('switching to another admin invalidates the review', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await operation('old');
      await user('admin-a');
      await screen(tester);
      await user('admin-b');
      await confirm(tester);
      expect(find.text('Session à vérifier'), findsOneWidget);
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['owner_user_local_id'],
        isNull,
      );
    });
  });
  for (final running in [false, true]) {
    testWidgets(
      running
          ? 'running mutation cannot be attributed'
          : 'unreadable mutation cannot be attributed',
      (tester) async {
        await tester.runAsync(() async {
          await operation('old', status: running ? 'running' : 'pending');
          await user('admin');
          await screen(
            tester,
            opener: running
                ? null
                : (_) async => throw const FormatException('synthetic'),
          );
          expect(
            tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
            isNull,
          );
        });
      },
    );
  }
  testWidgets('small viewport keeps the confirmation reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await operation('old');
      await user('admin');
      await screen(tester);
      await confirm(tester);
      expect(tester.takeException(), isNull);
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['owner_user_local_id'],
        'admin',
      );
    });
  });
  testWidgets('account switch while opening hides the previous review', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await operation('old');
      await user('admin-a');
      final started = Completer<void>();
      final release = Completer<String>();
      await screen(
        tester,
        waitForLoad: false,
        opener: (_) {
          started.complete();
          return release.future;
        },
      );
      await started.future;
      await user('admin-b');
      release.complete('{"updates":{"status":"SECRET-VALUE"}}');
      await settle(tester);
      expect(find.text('Session à vérifier'), findsOneWidget);
      expect(find.text('local-synthetic'), findsNothing);
    });
  });
  testWidgets('known owner mismatch asks to reconnect without reassignment', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await user('owner', role: 'ergo');
      await operation('owned');
      await user('other', role: 'ergo');
      await screen(tester);
      expect(find.text('Reconnexion de l’auteur nécessaire'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  for (final mutation in [
    'payload',
    'candidate',
    'owner',
    'running',
    'session',
    'inactive',
  ]) {
    test('self confirmation rejects a changed $mutation snapshot', () async {
      await operation('historical');
      await user('ergo', role: 'ergo');
      final snapshot = (await SyncOperationOwnership.listReviewableOperations(
        db,
      )).single;
      switch (mutation) {
        case 'payload':
          await db.update('sync_operations', {'payload_json': '{"new":true}'});
        case 'candidate':
          await db.update(SyncOperationOwnership.tableName, {
            'candidate_user_local_id': 'other',
          });
        case 'owner':
          await db.update(SyncOperationOwnership.tableName, {
            'owner_user_local_id': 'other',
          });
        case 'running':
          await db.update('sync_operations', {'status': 'running'});
        case 'session':
          await user('other', role: 'ergo');
        case 'inactive':
          await db.update('app_users', {'is_active': 0});
      }
      final before = await db.query('sync_operations');
      final accepted = await db.transaction(
        (txn) => SyncOwnershipSelfReview.confirm(
          txn: txn,
          expected: snapshot,
          userId: 'ergo',
        ),
      );
      expect(accepted, isFalse);
      expect(await db.query('sync_operations'), before);
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['attribution_state'],
        isNot(SyncOperationOwnership.reviewed),
      );
    });
  }

  test(
    'self confirmation history failure rolls back and retry is idempotent',
    () async {
      await operation('historical');
      await db.delete(SyncOperationOwnership.tableName);
      await user('ergo', role: 'ergo');
      final snapshot = (await SyncOperationOwnership.listReviewableOperations(
        db,
      )).single;
      await db.execute('''CREATE TRIGGER fail_history BEFORE INSERT ON
      ${SyncOperationOwnership.historyTableName}
      BEGIN SELECT RAISE(ABORT, 'synthetic'); END''');
      Future<bool> accept() => db.transaction(
        (txn) => SyncOwnershipSelfReview.confirm(
          txn: txn,
          expected: snapshot,
          userId: 'ergo',
        ),
      );
      await expectLater(accept(), throwsA(isA<DatabaseException>()));
      expect(await db.query(SyncOperationOwnership.tableName), isEmpty);
      expect(await db.query('sync_operations'), hasLength(1));
      await db.execute('DROP TRIGGER fail_history');
      expect(await accept(), isTrue);
      expect(await accept(), isFalse);
      expect(
        await db.query(SyncOperationOwnership.historyTableName),
        hasLength(1),
      );
      expect(await SyncOperationOwnership.mayClaim(db, 'historical'), isTrue);
    },
  );

  testWidgets('self review skips another account but offers unknown work', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await user('other', role: 'ergo');
      await operation('foreign');
      await db.update(SyncOperationOwnership.tableName, {
        'attribution_state': SyncOperationOwnership.reviewRequired,
      });
      await db.delete('app_session');
      await operation('unknown');
      await user('ergo', role: 'ergo');
      await screen(tester);
      await confirm(tester);
      expect(await SyncOperationOwnership.mayClaim(db, 'unknown'), isTrue);
      expect(await SyncOperationOwnership.mayClaim(db, 'foreign'), isFalse);
      expect(find.text('Reconnexion de l’auteur nécessaire'), findsOneWidget);
    });
  });
}
