import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/sync_mutation.dart';

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  const oldRef = {
    'recordId': 11,
    'revision': '11111111-1111-4111-8111-111111111111',
  };
  const newRef = {
    'recordId': 11,
    'revision': '22222222-2222-4222-8222-222222222222',
  };
  const guard = {
    'version': 1,
    'writeId': '33333333-3333-4333-8333-333333333333',
    'reference': oldRef,
    'expectedUpdatedAt': null,
    'baseValues': {
      'medicalContext': {'pathology': 'old'},
    },
  };
  const payload = {
    'concurrency': guard,
    'updates': {
      'medicalContext': {'pathology': 'new'},
    },
  };
  test(
    'context uses its own PUT endpoint and accepts revision-only ACK',
    () async {
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'PUT');
          expect(request.url.path, '/api/contextes/dossier');
          expect(jsonDecode(request.body), payload);
          return http.Response(
            jsonEncode({
              'data': {'serverReference': newRef},
            }),
            200,
          );
        }),
      );
      expect(
        jsonDecode(
          await client.updateContext(dossierId: 'dossier', payload: payload),
        )['revision'],
        newRef['revision'],
      );
    },
  );
  for (final ref in [
    null,
    {},
    {'recordId': 11, 'revision': 'bad'},
  ]) {
    test('invalid context ACK $ref stays retryable', () async {
      final client = NocodbApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {'serverReference': ref},
            }),
            200,
          ),
        ),
      );
      await expectLater(
        client.updateContext(dossierId: 'dossier', payload: payload),
        throwsA(isA<TransientRemoteException>()),
      );
    });
  }
  for (final reference in [oldRef, null]) {
    test(
      'own context ACK rebases queued successor with reference $reference',
      () {
        final sent = {
          ...payload,
          'concurrency': {
            ...guard,
            'reference': reference,
            if (reference == null) 'baseValues': <String, dynamic>{},
          },
        };
        final pending = {
          ...sent,
          'updates': {
            'medicalContext': {'pathology': 'latest'},
          },
          'concurrency': {
            ...sent['concurrency'] as Map,
            'writeId': '44444444-4444-4444-8444-444444444444',
            'predecessorWriteIds': [guard['writeId']],
          },
        };
        final result = rebaseAcknowledgedMutation(
          sent: sent,
          pending: pending,
          version: jsonEncode(newRef),
        );
        expect(result, isNotNull);
        expect(
          result!['concurrency']['reference']['revision'],
          newRef['revision'],
        );
        expect(result['concurrency']['baseValues'], payload['updates']);
        expect(result['updates'], pending['updates']);
      },
    );
  }
}
