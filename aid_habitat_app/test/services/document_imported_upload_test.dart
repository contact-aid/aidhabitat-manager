import 'dart:convert';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/document_upload_identity.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  for (final known in [true, false]) {
    test('imported PDF upload uses original identity (stored=$known)', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final local = LocalDatabase.forTesting(db);
      await local.createSchemaForTesting();
      addTearDown(() async {
        ConnectivityService().dispose();
        AppConfig.setApiBaseUrl('');
        AppConfig.clearAppSessionToken();
        await db.close();
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
      const id = 'remote_doc_imported';
      const oldPath = '/api/mobile-documents/before/content';
      const newPath = '/api/mobile-documents/after/content';
      const stamp = '2026-09-15T10:00:00Z';
      await db.insert('documents', {
        'local_id': id,
        'patient_local_id': 'patient',
        'title': 'Report',
        'file_name': 'report.pdf',
        'file_ext': 'pdf',
        'mime_type': 'application/pdf',
        'tags_json': '[]',
        'remote_file_path': oldPath,
        'remote_public_url': oldPath,
        'sync_state': 'pendingSync',
        'created_at': stamp,
        'updated_at': stamp,
      });
      if (known) {
        await storeDocumentUploadIdentity(
          db,
          'patient',
          id,
          'original-client-id',
        );
      }
      final payload = jsonEncode({
        'patientLocalId': 'patient',
        'documentLocalId': id,
        'dataUrl':
            'data:application/pdf;base64,${base64Encode(utf8.encode('%PDF-rotated-bytes'))}',
        'fileName': 'report.pdf',
        'mimeType': 'application/pdf',
      });
      await db.insert('sync_operations', {
        'id': 'upload',
        'entity_type': 'document',
        'entity_local_id': id,
        'operation_type': 'upload_file',
        'payload_json': payload,
        'status': 'pending',
        'created_at': stamp,
        'updated_at': stamp,
      });
      var reads = 0;
      var uploads = 0;
      final api = NocodbApiClient(
        client: MockClient((request) async {
          if (request.method == 'GET') {
            reads++;
            expect(request.url.path, '/api/documents/patient');
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {
                  'documents': [
                    {
                      'clientDocumentId': 'original-client-id',
                      'remotePath': oldPath,
                      'publicUrl': oldPath,
                    },
                  ],
                },
              }),
              200,
            );
          }
          uploads++;
          expect(request.method, 'POST');
          expect(
            request.body,
            contains('name="documentLocalId"\r\n\r\noriginal-client-id'),
          );
          expect(request.body, contains('%PDF-rotated-bytes'));
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'document': {'remotePath': newPath, 'publicUrl': newPath},
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
      expect(result.pushedOperations, 1);
      expect(uploads, 1);
      expect(reads, known ? 0 : 1);
      final row = (await db.query('documents')).single;
      expect(row['local_id'], id);
      expect(row['remote_file_path'], newPath);
      expect(
        (await db.query('sync_operations')).single['payload_json'],
        payload,
      );
    });
  }
}
