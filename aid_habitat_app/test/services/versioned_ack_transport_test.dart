import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('synthetic-token');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });
  for (final entity in ['patient', 'housing', 'dossier']) {
    Future<Object?> send(NocodbApiClient client) => switch (entity) {
      'patient' => client.updateBeneficiary(
        patientId: 'synthetic',
        updates: {},
      ),
      'housing' => client.updateLogement(
        beneficiaryId: 'synthetic',
        updates: {},
      ),
      _ => client.updateDossier(dossierId: 'synthetic', updates: {}),
    };
    for (final value in [
      null,
      '',
      'invalid',
      '2026-02-30T10:00:00Z',
      '2026-09-17',
    ]) {
      test('$entity missing or invalid ACK $value stays retryable', () async {
        final client = NocodbApiClient(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'data': {
                  'updatedAt': value,
                  if (entity == 'housing') 'id': 'housing-1',
                },
              }),
              200,
            ),
          ),
        );
        await expectLater(
          send(client),
          throwsA(isA<TransientRemoteException>()),
        );
      });
    }
    test('$entity preserves confirmed native timestamp', () async {
      const version = '2026-09-17 10:00:00.123456+00:00';
      final client = NocodbApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {
                'updatedAt': version,
                if (entity == 'housing') 'id': 'housing-1',
              },
            }),
            200,
          ),
        ),
      );
      final result = await send(client);
      if (entity == 'housing') {
        expect((result as HousingWriteResult).updatedAt, version);
        expect(result.id, 'housing-1');
      } else {
        expect(result, version);
      }
    });
  }

  test('housing acknowledgement without an ID remains retryable', () async {
    final client = NocodbApiClient(
      client: MockClient(
        (_) async =>
            http.Response('{"data":{"updatedAt":"2026-09-22T10:00:00Z"}}', 200),
      ),
    );
    await expectLater(
      client.updateLogement(beneficiaryId: 'synthetic', updates: {}),
      throwsA(isA<TransientRemoteException>()),
    );
  });
}
