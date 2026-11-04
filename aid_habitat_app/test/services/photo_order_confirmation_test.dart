import 'dart:convert';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  const order = {
    'mutationId': 'new-drag',
    'orderedDocumentIds': ['b', 'a'],
    'initializeOnly': false,
  };
  for (final kind in ['confirmed', 'stale-mutation', 'different-order']) {
    test('server photo order acknowledgement: $kind', () async {
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'PUT');
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'order': {
                  ...order,
                  'revision': 2,
                  if (kind == 'stale-mutation') 'mutationId': 'old-drag',
                  if (kind == 'different-order')
                    'orderedDocumentIds': ['a', 'b'],
                },
              },
            }),
            200,
          );
        }),
      );
      if (kind == 'confirmed') {
        expect(await client.saveVisitPhotoOrder('patient', order), 2);
      } else {
        await expectLater(
          client.saveVisitPhotoOrder('patient', order),
          throwsA(isA<TransientRemoteException>()),
        );
      }
    });
  }
}
