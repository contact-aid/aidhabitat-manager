import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/media_cache_service.dart';

void main() {
  late String previousBase;
  late String previousToken;
  setUp(() {
    previousBase = AppConfig.apiBaseUrl;
    previousToken = AppConfig.appSessionToken;
    AppConfig.setApiBaseUrl('https://api.aidhabitat.fr');
    AppConfig.setAppSessionToken('synthetic-session');
  });
  tearDown(() {
    AppConfig.setApiBaseUrl(previousBase);
    AppConfig.setAppSessionToken(previousToken);
  });
  test('current and historical private media receive authentication', () {
    for (final url in [
      '/api/mobile-documents/test/content',
      'https://api.aidhabitat.fr/uploads/test.png',
      'https://apps-aidhabitat-api-staging.z5avx1.easypanel.host/api/mobile-documents/test/content',
      'https://apps-aidhabitat-api-staging.z5avx1.easypanel.host/uploads/test.png',
    ]) {
      expect(MediaCacheService.authHeadersFor(url), {
        'X-App-Session': 'synthetic-session',
      }, reason: url);
    }
  });
  test('no token for external, lookalike or insecure origins', () {
    for (final url in [
      'https://api.aidhabitat.fr.attacker.test/uploads/test',
      'https://api.aidhabitat.fr@attacker.test/uploads/test',
      'https://api.aidhabitat.fr:444/uploads/test',
      'http://api.aidhabitat.fr/uploads/test',
      'https://huggingface.co/model',
      'https://apps-aidhabitat-api-staging.z5avx1.easypanel.host/other',
      'http://apps-aidhabitat-api-staging.z5avx1.easypanel.host/uploads/test',
    ]) {
      expect(MediaCacheService.authHeadersFor(url), isEmpty, reason: url);
    }
  });
  test('historical alias is not trusted by custom backends', () {
    AppConfig.setApiBaseUrl('https://example.test');
    expect(
      MediaCacheService.authHeadersFor(
        'https://apps-aidhabitat-api-staging.z5avx1.easypanel.host/uploads/test',
      ),
      isEmpty,
    );
  });
  test('API path boundaries and offline sessions are respected', () {
    AppConfig.setApiBaseUrl('https://example.test/backend');
    expect(
      MediaCacheService.authHeadersFor('https://example.test/backend/file'),
      isNotEmpty,
    );
    expect(
      MediaCacheService.authHeadersFor(
        'https://example.test/backend-other/file',
      ),
      isEmpty,
    );
    AppConfig.setAppSessionToken('local-auth:test');
    expect(
      MediaCacheService.authHeadersFor('https://example.test/backend/file'),
      isEmpty,
    );
  });
}
