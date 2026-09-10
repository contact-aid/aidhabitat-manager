import 'dart:convert';

import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _expected = '2026-09-01T10:00:00Z';
const _updated = '2026-09-10T10:00:00Z';
const _guard = {
  'version': 1,
  'writeId': '12345678-1234-4234-8234-123456789012',
  'expectedUpdatedAt': _expected,
  'baseValues': <String, dynamic>{},
};

Future<String?> _update(
  NocodbApiClient client,
  String route, {
  bool guarded = true,
}) {
  switch (route) {
    case 'mesures':
      return client.updateMesures(
        dossierId: 'remote-dossier',
        updates: {'observations': 'new'},
        expectedUpdatedAt: guarded ? _expected : null,
        concurrency: guarded ? _guard : null,
      );
    case 'observations':
      return client.updateObservations(
        dossierId: 'remote-dossier',
        updates: {'projetSouhaitUsage': 'new'},
        expectedUpdatedAt: guarded ? _expected : null,
        concurrency: guarded ? _guard : null,
      );
    default:
      return client.updateDiagnosticSanitaires(
        dossierId: 'remote-dossier',
        sdbInstances: const [],
        wcInstances: const [],
        expectedUpdatedAt: guarded ? _expected : null,
        concurrency: guarded ? _guard : null,
      );
  }
}

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://fake.test');
    AppConfig.setAppSessionToken('synthetic-token');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl('');
    AppConfig.clearAppSessionToken();
  });

  for (final route in ['mesures', 'observations', 'diagnostic-sanitaires']) {
    test(
      '$route transmits captured guard and returns child timestamp',
      () async {
        final client = NocodbApiClient(
          client: MockClient((request) async {
            expect(request.method, 'PUT');
            expect(request.url.path, '/api/$route/remote-dossier');
            final body = jsonDecode(request.body) as Map;
            expect(body['expectedUpdatedAt'], _expected);
            expect(body['concurrency'], _guard);
            return http.Response(
              jsonEncode({
                'data': {'updatedAt': _updated},
              }),
              200,
            );
          }),
        );
        expect(await _update(client, route), _updated);
      },
    );

    for (final body in ['{}', '{"data":{"updatedAt":"invalid"}}', '']) {
      test(
        '$route missing or invalid guarded ACK stays retryable for $body',
        () async {
          final client = NocodbApiClient(
            client: MockClient((_) async => http.Response(body, 200)),
          );
          await expectLater(
            _update(client, route),
            throwsA(isA<TransientRemoteException>()),
          );
        },
      );
      test('$route preserves legacy optional version for $body', () async {
        final client = NocodbApiClient(
          client: MockClient((request) async {
            final data = jsonDecode(request.body) as Map;
            expect(data.containsKey('expectedUpdatedAt'), isFalse);
            expect(data.containsKey('concurrency'), isFalse);
            return http.Response(body, 200);
          }),
        );
        expect(await _update(client, route, guarded: false), isNull);
      });
    }

    for (final status in [409, 428]) {
      test('$route retains $status remote conflict payload', () async {
        final remote = {
          'remoteData': {'updatedAt': _updated, 'value': 'remote'},
        };
        final client = NocodbApiClient(
          client: MockClient(
            (_) async => http.Response(jsonEncode(remote), status),
          ),
        );
        await expectLater(
          _update(client, route),
          throwsA(
            isA<ConflictException>().having(
              (e) => e.remoteData,
              'remoteData',
              remote,
            ),
          ),
        );
      });
    }

    for (final timestamp in [
      '2026-09-10',
      '2026-09-10T10:00:00',
      '2026-02-30T10:00:00Z',
    ]) {
      test(
        '$route rejects incomplete or normalized ACK timestamp $timestamp',
        () async {
          final client = NocodbApiClient(
            client: MockClient(
              (_) async => http.Response(
                jsonEncode({
                  'data': {'updatedAt': timestamp},
                }),
                200,
              ),
            ),
          );
          await expectLater(
            _update(client, route),
            throwsA(isA<TransientRemoteException>()),
          );
        },
      );
    }

    test('$route preserves zoned database timestamp precision', () async {
      const timestamp = '2026-09-10 10:00:00.123456+00:00';
      final client = NocodbApiClient(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {'updatedAt': timestamp},
            }),
            200,
          ),
        ),
      );
      expect(await _update(client, route), timestamp);
    });

    test('$route GET keeps own version and dossier identity', () async {
      final data = {'dossierId': 'remote-dossier', 'updatedAt': _updated};
      final client = NocodbApiClient(
        client: MockClient((request) async {
          expect(request.method, 'GET');
          return http.Response(jsonEncode(data), 200);
        }),
      );
      final result = switch (route) {
        'mesures' => await client.fetchMesuresPayload('remote-dossier'),
        'observations' => await client.fetchObservationsPayload(
          'remote-dossier',
        ),
        _ => await client.fetchDiagnosticSanitairePayload('remote-dossier'),
      };
      expect(result, data);
    });
  }
}
