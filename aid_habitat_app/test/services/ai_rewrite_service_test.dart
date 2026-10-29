import 'dart:convert';

import 'package:aid_habitat_app/services/ai_rewrite_service.dart';
import 'package:aid_habitat_app/services/ai_rewrite_context.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'note tabs select report context without sending an arbitrary heading',
    () {
      expect(aiRewriteContextForTab('Bénéficiaire-Notes'), 'living_context');
      expect(aiRewriteContextForTab('Contexte de vie-Médical'), 'medical');
      expect(aiRewriteContextForTab('Contexte de vie-Autonomie'), 'autonomy');
      expect(aiRewriteContextForTab('Contexte de vie'), 'living_context');
      expect(
        aiRewriteContextForTab('Contexte de vie-Habitudes'),
        'living_context',
      );
      expect(aiRewriteContextForTab('Autre titre'), 'general');
    },
  );

  test('the authenticated request carries the report section', () async {
    final service = AiRewriteService(
      client: MockClient((request) async {
        expect(jsonDecode(request.body)['context'], 'beneficiary');
        return http.Response(
          jsonEncode({
            'data': {'text': 'Note corrigée.'},
          }),
          200,
        );
      }),
    );
    expect(
      await service.rewrite(
        text: 'Note fictive.',
        context: 'beneficiary',
        apiBaseUrl: 'https://private.test',
        sessionToken: 'synthetic',
      ),
      'Note corrigée.',
    );
  });

  test('OpenRouter availability shares authenticated status probes', () async {
    var requests = 0;
    final service = AiRewriteService(
      client: MockClient((request) async {
        requests++;
        expect(request.headers['X-App-Session'], 'session-test');
        return http.Response(
          jsonEncode({
            'data': {
              'ready': true,
              'webEnabled': true,
              'provider': 'openrouter',
            },
          }),
          200,
        );
      }),
    );
    final probes = await Future.wait(
      List.generate(
        5,
        (_) => service.isServerRewriteAvailable(
          apiBaseUrl: 'https://private.test',
          sessionToken: 'session-test',
        ),
      ),
    );
    expect(probes, everyElement(isTrue));
    expect(requests, 1);
    expect(
      await service.isServerRewriteAvailable(
        apiBaseUrl: 'https://private.test',
        sessionToken: 'session-test',
      ),
      isTrue,
    );
    expect(requests, 1);
  });

  test(
    'an older ready server never enables browser note transmission',
    () async {
      final service = AiRewriteService(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': {'ready': true},
            }),
            200,
          ),
        ),
      );
      expect(
        await service.isServerRewriteAvailable(
          apiBaseUrl: 'https://private.test',
          sessionToken: 'session-test',
        ),
        isFalse,
      );
    },
  );

  test('server availability is isolated between sessions', () async {
    var requests = 0;
    final service = AiRewriteService(
      client: MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'data': {
              'ready': request.headers['X-App-Session'] == 'first',
              'webEnabled': true,
              'provider': 'openrouter',
            },
          }),
          200,
        );
      }),
    );
    expect(
      await service.isServerRewriteAvailable(
        apiBaseUrl: 'https://private.test',
        sessionToken: 'first',
      ),
      isTrue,
    );
    expect(
      await service.isServerRewriteAvailable(
        apiBaseUrl: 'https://private.test',
        sessionToken: 'second',
      ),
      isFalse,
    );
    expect(requests, 2);
  });

  test('returns the rewritten note from the authenticated endpoint', () async {
    late http.Request capturedRequest;
    final service = AiRewriteService(
      client: MockClient((request) async {
        capturedRequest = request;
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'text':
                  'Mme Test rencontre des difficultés pour accéder à la douche.',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final result = await service.rewrite(
      text: 'Mme Test a du mal à rentrer dans la douche.',
      apiBaseUrl: 'http://127.0.0.1:3001/',
      sessionToken: 'session-test',
    );

    expect(
      capturedRequest.url.toString(),
      'http://127.0.0.1:3001/api/ai/rewrite',
    );
    expect(capturedRequest.headers['X-App-Session'], 'session-test');
    expect(jsonDecode(capturedRequest.body), {
      'text': 'Mme Test a du mal à rentrer dans la douche.',
      'mode': 'professional',
      'context': 'general',
    });
    expect(
      result,
      'Mme Test rencontre des difficultés pour accéder à la douche.',
    );
  });

  test('surfaces a safe server error', () async {
    final service = AiRewriteService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'success': false,
            'error': "La proposition n'était pas assez fidèle.",
          }),
          422,
        ),
      ),
    );

    expect(
      () => service.rewrite(
        text: 'Texte à reformuler.',
        apiBaseUrl: 'http://127.0.0.1:3001',
        sessionToken: 'session-test',
      ),
      throwsA(
        isA<Exception>().having(
          (error) => error.toString(),
          'message',
          contains("La proposition n'était pas assez fidèle."),
        ),
      ),
    );
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    test(
      '$platform always uses OpenRouter through the authenticated server',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        var calls = 0;
        final service = AiRewriteService(
          client: MockClient((request) async {
            calls++;
            if (request.method == 'GET') {
              return http.Response(
                jsonEncode({
                  'data': {'ready': true, 'provider': 'openrouter'},
                }),
                200,
              );
            }
            expect(request.url.path, '/api/ai/rewrite');
            return http.Response(
              jsonEncode({
                'data': {'text': 'Proposition modifiable.'},
              }),
              200,
            );
          }),
        );
        expect(
          await service.isAvailable(
            apiBaseUrl: 'https://private.test',
            sessionToken: 'synthetic',
          ),
          true,
        );
        expect(
          await service.rewrite(
            text: 'Note fictive.',
            apiBaseUrl: 'https://private.test',
            sessionToken: 'synthetic',
          ),
          'Proposition modifiable.',
        );
        expect(calls, 2);
      },
    );
  }

  test('rejects invalid note lengths before contacting the server', () async {
    var calls = 0;
    final service = AiRewriteService(
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
    );
    for (final text in ['', 'ab', 'a' * 8001]) {
      expect(() => service.rewrite(text: text), throwsException);
    }
    expect(calls, 0);
  });
}
