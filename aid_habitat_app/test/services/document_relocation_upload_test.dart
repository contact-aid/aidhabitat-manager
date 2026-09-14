import 'dart:convert';
import 'dart:io';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// The platform fake is test-only; path_provider supplies this interface transitively.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final present in [true, false]) {
    test(
      'queued old-container upload (file present=$present) preserves intent',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'relocation-upload-',
        );
        final oldProvider = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        addTearDown(() async {
          ConnectivityService().dispose();
          AppConfig.setApiBaseUrl('');
          AppConfig.clearAppSessionToken();
          PathProviderPlatform.instance = oldProvider;
          await db.close();
          await root.delete(recursive: true);
        });
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
        await ConnectivityService().initialize();
        AppConfig.setApiBaseUrl('https://synthetic.invalid');
        AppConfig.setAppSessionToken('synthetic');
        const path =
            '/missing/OLD/Documents/document_revisions/revision_exact/content.pdf';
        if (present) {
          final file = File(
            '${root.path}/document_revisions/revision_exact/content.pdf',
          );
          await file.parent.create(recursive: true);
          await file.writeAsString('%PDF-synthetic-preserved');
        }
        const stamp = '2026-09-14T00:00:00.000Z';
        final payload = jsonEncode({
          'patientLocalId': 'patient',
          'documentLocalId': 'doc',
          'localPath': path,
          'fileName': 'content.pdf',
          'mimeType': 'application/pdf',
        });
        await db.insert('documents', {
          'local_id': 'doc',
          'patient_local_id': 'patient',
          'file_name': 'content.pdf',
          'file_ext': 'pdf',
          'mime_type': 'application/pdf',
          'title': 'Synthetic',
          'tags_json': '[]',
          'local_file_path': path,
          'created_at': stamp,
          'updated_at': stamp,
          'sync_state': 'pendingSync',
        });
        await db.insert('sync_operations', {
          'id': 'upload',
          'entity_type': 'document',
          'entity_local_id': 'doc',
          'operation_type': 'upload_file',
          'status': 'pending',
          'payload_json': payload,
          'created_at': stamp,
          'updated_at': stamp,
        });
        var requests = 0;
        final api = NocodbApiClient(
          client: MockClient((request) async {
            requests++;
            expect(request.body, contains('%PDF-synthetic-preserved'));
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'document': {
                    'remotePath': 'remote-exact',
                    'publicUrl': 'https://synthetic.invalid/doc',
                  },
                },
              }),
              200,
            );
          }),
        );
        final result = await NocodbSyncService(
          database: local,
          apiClient: api,
          syncRepository: SyncRepository.forTesting(database: local),
        ).pushPendingChanges();
        final operation = (await db.query('sync_operations')).single;
        expect(operation['payload_json'], payload);
        expect(operation['id'], 'upload');
        expect(requests, present ? 1 : 0);
        expect(result.pushedOperations, present ? 1 : 0);
        expect(operation['status'], present ? 'completed' : 'failed');
      },
    );
  }
}
