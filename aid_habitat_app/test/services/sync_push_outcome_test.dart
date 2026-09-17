import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Queue extends SyncRepository {
  final bool acknowledge;
  _Queue({this.acknowledge = true, this.payload, this.unreadableFirst = false});
  final bool unreadableFirst;
  final String? payload;
  final completed = <String>[];
  final failed = <String>[];
  final deferred = <String>[];
  final conflicts = <String>[];

  @override
  Future<int> countConflictingOperations() async => 0;

  @override
  Future<bool> markConflict({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
    required String expectedPayloadJson,
    Map<String, dynamic>? remoteData,
  }) async {
    conflicts.add(operationId);
    return acknowledge;
  }

  @override
  Future<int> rehabilitateTransientFailures() async => 0;
  @override
  Future<int> recoverInterruptedDocumentUploads({
    Duration maxRunningAge = const Duration(minutes: 2),
  }) async => 0;
  @override
  Future<List<SyncOperation>> fetchRunnableOperations({
    bool includePayloads = true,
  }) async => [
    for (final id in ['first', 'following'])
      SyncOperation(
        id: id,
        entityType: 'dossier',
        entityLocalId: unreadableFirst ? id : 'dossier-1',
        operationType: 'update',
        payloadJson:
            payload ??
            '{"dossierId":"dossier-1","updates":{"status":"EN_COURS"}}',
        status: SyncOperationStatus.pending,
        attemptCount: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
  ];
  @override
  Future<SyncOperation?> loadRunnablePayload(SyncOperation snapshot) async {
    if (unreadableFirst && snapshot.id == 'first') {
      throw const FormatException('Synthetic unreadable vault payload');
    }
    return snapshot;
  }

  @override
  Future<bool> markPreparationFailure(SyncOperation snapshot) async {
    failed.add(snapshot.id);
    return true;
  }

  @override
  Future<bool> tryMarkRunning(SyncOperation operation) async => true;
  @override
  Future<void> storeRemoteUpdatedAt(
    SyncOperation operation,
    String? value,
  ) async {}
  @override
  Future<bool> acknowledgeVersionedMutation(
    SyncOperation operation,
    String? version,
  ) => markCompleted(
    operationId: operation.id,
    entityType: operation.entityType,
    entityLocalId: operation.entityLocalId,
  );
  @override
  Future<bool> markCompleted({
    required String operationId,
    required String entityType,
    required String entityLocalId,
  }) async {
    if (acknowledge) completed.add(operationId);
    return acknowledge;
  }

  @override
  Future<void> markFailed({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    failed.add(operationId);
  }

  @override
  Future<void> markTransientFailure({
    required String operationId,
    required String entityType,
    required String entityLocalId,
    required String error,
  }) async {
    deferred.add(operationId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => ['wifi'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (call) async => null,
    );
    AppConfig.setApiBaseUrl('https://fake.test');
    AppConfig.setAppSessionToken('synthetic-token');
    await ConnectivityService().initialize();
  });
  tearDown(() {
    ConnectivityService().dispose();
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });

  test(
    'logout stops following operations and rejects the old acknowledgement',
    () async {
      final queue = _Queue(
        payload: jsonEncode({
          'dossierId': 'dossier-1',
          'updates': {'status': 'NEW'},
          'concurrency': {
            'version': 1,
            'writeId': '12345678-1234-4234-8234-123456789012',
            'expectedUpdatedAt': '2026-09-01T10:00:00Z',
            'baseValues': {'status': 'OLD'},
          },
        }),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      var sent = 0;
      final service = NocodbSyncService(
        syncRepository: queue,
        apiClient: NocodbApiClient(
          client: MockClient((request) async {
            sent++;
            expect(request.headers['X-App-Session'], 'synthetic-token');
            entered.complete();
            await release.future;
            return http.Response(
              '{"data":{"updatedAt":"2026-09-10T10:00:00Z"}}',
              200,
            );
          }),
        ),
      );
      final push = service.pushPendingChanges();
      await entered.future;
      AppConfig.clearAppSessionToken();
      AppConfig.setAppSessionToken('next-account');
      release.complete();
      final result = await push;
      expect(sent, 1);
      expect(queue.completed, isEmpty);
      expect(queue.deferred, ['first']);
      expect(result.pushedOperations, 0);
    },
  );

  test('unreadable payload does not block another entity', () async {
    final queue = _Queue(unreadableFirst: true);
    var sent = 0;
    final service = NocodbSyncService(
      syncRepository: queue,
      apiClient: NocodbApiClient(
        client: MockClient((request) async {
          sent++;
          return http.Response('{"data":{}}', 200);
        }),
      ),
    );
    final result = await service.pushPendingChanges();
    expect(sent, 1);
    expect(queue.failed, ['first']);
    expect(queue.completed, ['following']);
    expect(result.failedOperations, 1);
    expect(result.pushedOperations, 1);
  });

  test(
    'the saved baseline and mutation id are transmitted unchanged on retry',
    () async {
      const guard = {
        'version': 1,
        'writeId': '12345678-1234-4234-8234-123456789012',
        'expectedUpdatedAt': '2026-09-01T10:00:00Z',
        'baseValues': {'status': 'OLD'},
      };
      final queue = _Queue(
        payload: jsonEncode({
          'dossierId': 'dossier-1',
          'updates': {'status': 'NEW'},
          'concurrency': guard,
        }),
      );
      var requests = 0;
      final client = NocodbApiClient(
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body);
          expect(body['concurrency'], guard);
          expect(body['expectedUpdatedAt'], guard['expectedUpdatedAt']);
          return http.Response('{"error":"temporary"}', 503);
        }),
      );
      final service = NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      );
      await service.pushPendingChanges();
      await service.pushPendingChanges();
      expect(requests, 2);
      expect(queue.deferred, ['first', 'first']);
      expect(queue.completed, isEmpty);
    },
  );

  test(
    'a missing saved version requires review instead of using a fresh baseline',
    () async {
      final queue = _Queue(
        payload: jsonEncode({
          'dossierId': 'dossier-1',
          'updates': {'status': 'NEW'},
          'concurrency': {'version': 1, 'expectedUpdatedAt': null},
        }),
      );
      final client = NocodbApiClient(
        client: MockClient((_) async {
          fail('No unguarded HTTP request allowed');
        }),
      );
      final result = await NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      expect(result.conflictCount, 1);
      expect(queue.completed, isEmpty);
    },
  );

  for (final retryStatus in [200, 400, 503]) {
    test(
      '409 never retries unconditionally (following response would be $retryStatus)',
      () async {
        var requests = 0;
        final queue = _Queue();
        final client = NocodbApiClient(
          client: MockClient((request) async {
            final status = ++requests == 1 ? 409 : retryStatus;
            return http.Response(
              status == 200
                  ? '{"success":true,"data":{}}'
                  : '{"error":"synthetic failure"}',
              status,
            );
          }),
        );
        final result = await NocodbSyncService(
          apiClient: client,
          syncRepository: queue,
        ).pushPendingChanges();
        expect(requests, 1);
        expect(result.pushedOperations, 0);
        expect(result.failedOperations, 0);
        expect(result.deferredOperations, 0);
        expect(result.conflictCount, 1);
        expect(queue.conflicts, ['first']);
        expect(queue.completed, isEmpty);
      },
    );
  }

  for (final conflictFirst in [false, true]) {
    test(
      'a replaced mutation is not counted as synchronized (conflict=$conflictFirst)',
      () async {
        var requests = 0;
        final queue = _Queue(acknowledge: false);
        final client = NocodbApiClient(
          client: MockClient((request) async {
            requests++;
            return http.Response(
              '{"success":true,"data":{}}',
              conflictFirst && requests == 1 ? 409 : 200,
            );
          }),
        );
        final result = await NocodbSyncService(
          apiClient: client,
          syncRepository: queue,
        ).pushPendingChanges();
        expect(requests, 1);
        expect(result.pushedOperations, 0);
        expect(result.deferredOperations, 1);
        expect(queue.completed, isEmpty);
      },
    );
  }

  test(
    'manual and automatic pushes across instances join a single drain',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var requests = 0;
      final queue = _Queue();
      final client = NocodbApiClient(
        client: MockClient((request) async {
          if (++requests == 1) {
            entered.complete();
            await release.future;
          }
          return http.Response('{"success":true,"data":{}}', 200);
        }),
      );
      final first = NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      await entered.future;
      final second = NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      expect(identical(first, second), isTrue);
      release.complete();
      final results = await Future.wait([first, second]);
      expect(requests, 2);
      expect(queue.completed, ['first', 'following']);
      expect(results.every((result) => result.pushedOperations == 2), isTrue);
      await NocodbSyncService(
        apiClient: client,
        syncRepository: queue,
      ).pushPendingChanges();
      expect(requests, 4, reason: 'the completed drain must release its lock');
    },
  );
}
