import 'dart:async';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    AppConfig.setApiBaseUrl('https://dossiers.synthetic.invalid');
    AppConfig.setAppSessionToken('synthetic-session');
  });
  tearDown(() => AppConfig.setAppSessionToken(''));
  test(
    'slow reply does not resolve as an empty list before it arrives',
    () async {
      final response = Completer<http.Response>();
      final api = NocodbApiClient(client: MockClient((_) => response.future));
      var finished = false;
      final pending = api.fetchDossierPayloads().then((rows) {
        finished = true;
        return rows;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      response.complete(http.Response('[{"id":"synthetic"}]', 200));
      expect((await pending).single['id'], 'synthetic');
    },
  );
  test(
    'successful empty response is distinguishable from request failure',
    () async {
      final api = NocodbApiClient(
        client: MockClient((_) async => http.Response('[]', 200)),
      );
      expect(await api.fetchDossierPayloads(), isEmpty);
    },
  );
  for (final body in ['{}', '[null]', '[{"id":"synthetic"},false]']) {
    test(
      'malformed dossier response is not converted to an empty success: $body',
      () async {
        final api = NocodbApiClient(
          client: MockClient((_) async => http.Response(body, 200)),
        );
        await expectLater(api.fetchDossierPayloads(), throwsException);
      },
    );
  }
  test('server failure does not become an empty result', () async {
    final api = NocodbApiClient(
      client: MockClient((_) async => http.Response('{}', 503)),
    );
    await expectLater(api.fetchDossierPayloads(), throwsException);
  });
}
