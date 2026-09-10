import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:aid_habitat_app/services/wiki_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Database db;
  late LocalDatabase local;
  late WikiRepository wiki;
  late SyncRepository queue;
  const stamp = '2026-09-10T00:00:00.000Z';
  const remoteId = 'remote-wiki-1';
  const imageB = 'data:image/png;base64,Qg==';

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    local = LocalDatabase.forTesting(db);
    await local.createSchemaForTesting();
    wiki = WikiRepository(database: local);
    queue = SyncRepository.forTesting(database: local);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    AppConfig.setApiBaseUrl('https://wiki.synthetic.invalid');
    AppConfig.setAppSessionToken('synthetic-session');
    await ConnectivityService().initialize();
  });
  tearDown(() async {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
    await db.close();
  });

  http.Response response(String title) => http.Response(
    jsonEncode({
      'success': true,
      'data': {
        'item': {
          'id': remoteId,
          'title': title,
          'description': title,
          'imageUrl': 'https://wiki.synthetic.invalid/image-$title',
          'tags': [],
          'category': '',
          'createdAt': stamp,
          'updatedAt': stamp,
        },
      },
    }),
    200,
  );

  for (final scenario in ['create-edit', 'create-delete', 'update-image']) {
    test('real sync processor with deferred HTTP: $scenario', () async {
      final firstRequest = Completer<http.Request>();
      final firstResponse = Completer<http.Response>();
      final requests = <http.Request>[];
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.url.origin, 'https://wiki.synthetic.invalid');
          expect(request.headers['X-App-Session'], 'synthetic-session');
          requests.add(request);
          if (requests.length == 1) {
            firstRequest.complete(request);
            return firstResponse.future;
          }
          expect(request.url.path, '/api/wiki-library/$remoteId');
          if (scenario == 'create-delete') {
            expect(request.method, 'DELETE');
            return http.Response('{}', 200);
          }
          expect(request.method, 'PUT');
          final body = jsonDecode(request.body) as Map;
          expect(body['title'], 'B');
          expect(body['imageDataUrl'], imageB);
          return response('B');
        }),
      );
      final service = NocodbSyncService(
        database: local,
        syncRepository: queue,
        apiClient: client,
      );

      late WikiItem current;
      if (scenario == 'update-image') {
        await db.insert('wiki_items', {
          'id': remoteId,
          'title': 'Original',
          'description': '',
          'image_url': '',
          'tags_json': '[]',
          'category': '',
          'created_at': stamp,
          'updated_at': stamp,
          'last_synced_at': stamp,
          'sync_state': 'synced',
        });
        current = WikiItem(
          id: remoteId,
          title: 'A',
          description: 'A',
          imageUrl: '',
          tags: const [],
          category: '',
          createdAt: stamp,
          updatedAt: stamp,
        );
        await wiki.updateLocalItem(current);
      } else {
        current = await wiki.createLocalDraft(
          title: 'A',
          description: 'A',
          category: '',
          tags: const [],
        );
      }
      final run = service.pushPendingChanges();
      addTearDown(() async {
        if (!firstResponse.isCompleted) firstResponse.complete(response('A'));
        await run;
      });
      final sent = await firstRequest.future.timeout(
        const Duration(seconds: 5),
      );
      expect(sent.method, scenario == 'update-image' ? 'PUT' : 'POST');
      expect(jsonDecode(sent.body)['title'], 'A');
      final claimed = (await db.query(
        'sync_operations',
        where: 'status = ?',
        whereArgs: ['running'],
      )).single;

      if (scenario == 'create-delete') {
        await wiki.deleteLocalItem(current.id);
      } else {
        await wiki.updateLocalItem(
          current.copyWith(title: 'B', description: 'B'),
          imageDataUrl: imageB,
        );
      }
      final stillClaimed = (await db.query(
        'sync_operations',
        where: 'id = ?',
        whereArgs: [claimed['id']],
      )).single;
      expect(stillClaimed['status'], 'running');
      expect(stillClaimed['payload_json'], claimed['payload_json']);
      firstResponse.complete(response('A'));
      final firstResult = await run;
      expect(firstResult.failedOperations, 0);
      expect(firstResult.pushedOperations, 1);
      expect(requests, hasLength(1));

      final row = (await db.query('wiki_items')).single;
      expect(row['id'], remoteId);
      expect(row['sync_state'], 'pendingSync');
      if (scenario == 'create-delete') {
        expect(row['pending_delete'], 1);
      } else {
        expect(row['title'], 'B');
        expect(row['pending_image_data_url'], imageB);
      }
      final following = (await db.query(
        'sync_operations',
        where: 'status = ?',
        whereArgs: ['pending'],
      )).single;
      expect(following['entity_local_id'], remoteId);
      expect(
        following['operation_type'],
        scenario == 'create-delete' ? 'delete' : 'update',
      );
      final secondResult = await service.pushPendingChanges();
      expect(secondResult.failedOperations, 0);
      expect(secondResult.pushedOperations, 1);
      expect(requests, hasLength(2));
      expect(
        (await db.query(
          'sync_operations',
        )).every((op) => op['status'] == 'completed'),
        isTrue,
      );
      final finalRows = await db.query('wiki_items');
      if (scenario == 'create-delete') {
        expect(finalRows, isEmpty);
      } else {
        expect(finalRows.single['title'], 'B');
        expect(finalRows.single['sync_state'], 'synced');
        expect(finalRows.single['pending_image_data_url'], isNull);
      }
    });
  }
}
