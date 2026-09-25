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

class _NoteQueue extends SyncRepository {
  _NoteQueue(this.operation);

  final SyncOperation operation;
  var completed = false;
  final conflicts = <String>[];

  @override
  Future<int> countConflictingOperations() async => 0;

  @override
  Future<int> rehabilitateTransientFailures() async => 0;

  @override
  Future<int> recoverInterruptedDocumentUploads({
    Duration maxRunningAge = const Duration(minutes: 2),
  }) async => 0;

  @override
  Future<List<SyncOperation>> fetchRunnableOperations({
    bool includePayloads = true,
  }) async => completed ? const [] : [operation];

  @override
  Future<SyncOperation?> loadRunnablePayload(SyncOperation snapshot) async =>
      snapshot;

  @override
  Future<bool> tryMarkRunning(SyncOperation operation) async => true;

  @override
  Future<bool> acknowledgeNotePageMutation(
    SyncOperation operation, {
    required String revision,
    required String remotePath,
    required String remoteUrl,
  }) async {
    completed = true;
    return true;
  }

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
    return true;
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

  test('an existing remote note is addressed by its canonical key', () async {
    const revision = '00000000-0000-4000-8000-000000000011';
    const writeId = '00000000-0000-4000-8000-000000000012';
    final payload = jsonEncode({
      'patientLocalId': 'nocodb-beneficiaire-62',
      'dossierId': 'airtable:dossier-62',
      'scopeType': 'dossier_detail',
      'scopeId': 'airtable:dossier-62',
      'tabKey': 'notes_rapides',
      'pageNumber': 0,
      'drawingJson': '{"version":1,"text":"edited","strokes":[]}',
      'expectedRevision': revision,
      'writeId': writeId,
    });
    final queue = _NoteQueue(
      SyncOperation(
        id: 'sync_note_nocodb-beneficiaire-62_notes_rapides_0',
        entityType: 'note_page',
        entityLocalId: 'note_nocodb-beneficiaire-62_notes_rapides_0',
        operationType: 'upsert',
        payloadJson: payload,
        status: SyncOperationStatus.pending,
        attemptCount: 0,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final client = NocodbApiClient(
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(request.method, 'PUT');
        expect(body['notePageId'], isEmpty);
        expect(body['expectedRevision'], revision);
        expect(body['writeId'], writeId);
        return http.Response(
          '{"success":true,"data":{"notePage":'
          '{"id":"remote-note","revision":"$writeId"}}}',
          200,
        );
      }),
    );

    final result = await NocodbSyncService(
      apiClient: client,
      syncRepository: queue,
    ).pushPendingChanges();

    expect(result.pushedOperations, 1);
    expect(queue.completed, isTrue);
    expect(queue.conflicts, isEmpty);
  });
}
