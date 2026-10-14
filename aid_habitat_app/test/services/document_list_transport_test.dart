import 'dart:convert';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://documents.synthetic.invalid');
    AppConfig.setAppSessionToken('synthetic');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  test(
    'each incoming list bypasses browser caches and preserves all PDFs',
    () async {
      final reads = <http.Request>[];
      final docs = List.generate(
        4,
        (i) => {
          'id': 'scan-$i',
          'remotePath': '/content/$i',
          'fileName': 'scan-$i.pdf',
          'mimeType': 'application/pdf',
          'tags': ['Autre'],
        },
      );
      final api = NocodbApiClient(
        client: MockClient((request) async {
          reads.add(request);
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'documents': docs},
            }),
            200,
          );
        }),
      );
      expect(await api.fetchDocuments('patient'), docs);
      expect(await api.fetchDocuments('patient'), docs);
      expect(
        reads.map((r) => r.url.queryParameters['_syncRead']).toSet(),
        hasLength(2),
      );
      // The deployed API allows Content-Type and X-App-Session in CORS.
      // A Cache-Control request header would block browser reads entirely.
      expect(
        reads.every((r) => !r.headers.containsKey('Cache-Control')),
        isTrue,
      );
    },
  );
  for (final body in [
    '{}',
    '{"success":false,"data":{"documents":[]}}',
    '{"success":true,"data":{}}',
    '{"success":true,"data":{"documents":[null]}}',
    '{"success":true,"data":{"documents":[{},null]}}',
    '{"success":true,"data":{"documents":[{}]}}',
    '{"success":true,"data":{"documents":[{"id":"scan"}]}}',
  ]) {
    test(
      'incomplete list is rejected before reconciling local documents: $body',
      () async {
        final api = NocodbApiClient(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(api.fetchDocuments('patient'), throwsFormatException);
      },
    );
  }
  test('explicit successful empty list remains supported', () async {
    final api = NocodbApiClient(
      client: MockClient(
        (_) async =>
            http.Response('{"success":true,"data":{"documents":[]}}', 200),
      ),
    );
    expect(await api.fetchDocuments('patient'), isEmpty);
  });
}
