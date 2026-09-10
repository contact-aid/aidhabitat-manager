import 'dart:async';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUp(() {
    AppConfig.setApiBaseUrl('https://synthetic.test');
    AppConfig.setAppSessionToken('account-a');
  });
  tearDown(AppConfig.clearAppSessionToken);

  Future<String?> save(NocodbApiClient client) => client.updateMesures(
    dossierId: 'synthetic',
    updates: {'observations': 'draft'},
  );

  test('delayed work never adopts the next account token', () async {
    var requests = 0;
    final client = NocodbApiClient(
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    final scope = SyncSessionScope();
    AppConfig.clearAppSessionToken();
    AppConfig.setAppSessionToken('account-b');
    await expectLater(
      scope.run(() => save(client)),
      throwsA(isA<TransientRemoteException>()),
    );
    expect(requests, 0);
  });

  test('response arriving after logout is not applied', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final client = NocodbApiClient(
      client: MockClient((request) async {
        expect(request.headers['X-App-Session'], 'account-a');
        entered.complete();
        await release.future;
        return http.Response('{}', 200);
      }),
    );
    final result = expectLater(
      SyncSessionScope().run(() => save(client)),
      throwsA(isA<TransientRemoteException>()),
    );
    await entered.future;
    AppConfig.clearAppSessionToken();
    AppConfig.setAppSessionToken('account-b');
    release.complete();
    await result;
  });

  test('queued JSON batch is fenced before sending', () async {
    var requests = 0;
    final client = NocodbApiClient(
      enableJsonBatching: true,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    final result = expectLater(
      save(client),
      throwsA(isA<TransientRemoteException>()),
    );
    AppConfig.clearAppSessionToken();
    AppConfig.setAppSessionToken('account-b');
    await result;
    expect(requests, 0);
  });
}
