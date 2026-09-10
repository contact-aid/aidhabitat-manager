import 'dart:async';
import 'package:aid_habitat_app/screens/sync_ownership_review_screen.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/sync_operation_ownership.dart';
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

  Future<void> settle(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }

  Future<void> screen(
    WidgetTester tester, {
    SyncPayloadOpener? opener,
    VoidCallback? onReviewed,
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
    await settle(tester);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.ensureVisible(find.byType(FilledButton));
    await tester.tap(find.byType(FilledButton));
    await settle(tester);
  }

  testWidgets('non-admin cannot inspect or attribute the queue', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await operation('old');
      await user('ergo', role: 'ergo');
      await screen(tester);
      expect(find.text('Accès administrateur requis'), findsOneWidget);
      expect(find.textContaining('Champs concernés'), findsNothing);
      expect(
        (await db.query(
          SyncOperationOwnership.tableName,
        )).single['owner_user_local_id'],
        isNull,
      );
    });
  });
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
      expect(find.text('Accès administrateur requis'), findsOneWidget);
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
        opener: (_) {
          started.complete();
          return release.future;
        },
      );
      await started.future;
      await user('admin-b');
      release.complete('{"updates":{"status":"SECRET-VALUE"}}');
      await settle(tester);
      expect(find.text('Accès administrateur requis'), findsOneWidget);
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
}
