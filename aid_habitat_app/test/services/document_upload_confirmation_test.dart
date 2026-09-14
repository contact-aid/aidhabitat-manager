import 'dart:convert';
import 'dart:typed_data';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppConfig.setApiBaseUrl('https://upload.synthetic.invalid');
    AppConfig.setAppSessionToken('synthetic');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  for (final chunked in [false, true]) {
    for (final body in [
      'not-json',
      '{"success":false,"data":{"document":{"remotePath":"p","publicUrl":"u"}}}',
      '{"data":{"document":{"remotePath":"p","publicUrl":"u"}}}',
    ]) {
      test('invalid success envelope chunked=$chunked body=$body', () async {
        final api = NocodbApiClient(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(
          api.uploadDocument(
            patientId: 'p',
            documentLocalId: 'd',
            title: 'Synthetic',
            fileName: 'test.pdf',
            mimeType: 'application/pdf',
            tags: [],
            bytes: Uint8List(chunked ? 1500 * 1024 : 10),
          ),
          throwsA(isA<TransientRemoteException>()),
        );
      });
    }
    for (final document in <dynamic>[
      null,
      {},
      {'remotePath': 'path'},
      {'publicUrl': 'https://synthetic.invalid/doc'},
      {'remotePath': ' ', 'publicUrl': 'url'},
      {'remotePath': 42, 'publicUrl': 'url'},
      {'remotePath': 'path', 'publicUrl': ''},
      {'remotePath': 'path', 'publicUrl': 'https://synthetic.invalid/doc'},
    ]) {
      final valid =
          document is Map &&
          document['remotePath'] == 'path' &&
          document['publicUrl'] == 'https://synthetic.invalid/doc';
      test('upload confirmation chunked=$chunked document=$document', () async {
        final api = NocodbApiClient(
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'success': true,
                'data': {'document': document},
              }),
              200,
            ),
          ),
        );
        final upload = api.uploadDocument(
          patientId: 'p',
          documentLocalId: 'd',
          title: 'Synthetic',
          fileName: 'test.pdf',
          mimeType: 'application/pdf',
          tags: [],
          bytes: Uint8List(chunked ? 1500 * 1024 : 10),
        );
        if (valid) {
          expect((await upload)['remotePath'], 'path');
        } else {
          await expectLater(upload, throwsA(isA<TransientRemoteException>()));
        }
      });
    }
  }
}
