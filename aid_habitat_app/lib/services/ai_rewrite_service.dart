import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_config.dart';

/// Notes are reformulated exclusively through the authenticated OpenRouter API.
class AiRewriteService {
  AiRewriteService({http.Client? client}) : _client = client ?? http.Client();
  static final AiRewriteService instance = AiRewriteService();
  final http.Client _client;
  Future<bool>? _serverProbe;
  String? _serverProbeKey;
  DateTime? _serverProbeExpires;

  Future<bool> isAvailable({
    bool refresh = false,
    String? apiBaseUrl,
    String? sessionToken,
  }) => isServerRewriteAvailable(
    apiBaseUrl: apiBaseUrl,
    sessionToken: sessionToken,
  );

  Future<bool> isServerRewriteAvailable({
    String? apiBaseUrl,
    String? sessionToken,
  }) {
    final base = (apiBaseUrl ?? AppConfig.apiBaseUrl).trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final token = (sessionToken ?? AppConfig.appSessionToken).trim();
    if (base.isEmpty || token.isEmpty) return Future.value(false);
    final key = '$base|$token|${AppConfig.sessionEpoch}';
    if (_serverProbeKey == key &&
        _serverProbe != null &&
        (_serverProbeExpires == null ||
            DateTime.now().isBefore(_serverProbeExpires!))) {
      return _serverProbe!;
    }
    _serverProbeKey = key;
    _serverProbeExpires = null;
    final probe = _remoteAvailable(base, token);
    _serverProbe = probe;
    probe.then((ready) {
      if (_serverProbeKey == key && identical(_serverProbe, probe)) {
        _serverProbeExpires = DateTime.now().add(
          Duration(seconds: ready ? 30 : 5),
        );
      }
    });
    return probe;
  }

  Future<bool> _remoteAvailable(String base, String token) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$base/api/ai/status'),
            headers: {'X-App-Session': token},
          )
          .timeout(const Duration(seconds: 7));
      if (response.statusCode != 200) return false;
      final payload = jsonDecode(response.body);
      final data = payload is Map ? payload['data'] : null;
      return data is Map &&
          data['ready'] == true &&
          data['provider'] == 'openrouter';
    } catch (_) {
      return false;
    }
  }

  Future<String> rewrite({
    required String text,
    String mode = 'professional',
    String context = 'general',
    String? apiBaseUrl,
    String? sessionToken,
  }) {
    final source = text.trim();
    if (source.length < 3) {
      throw Exception('La note est trop courte pour être reformulée.');
    }
    if (source.length > 8000) {
      throw Exception('La note ne doit pas dépasser 8000 caractères.');
    }
    return _rewriteRemotely(
      text: source,
      mode: mode,
      context: context,
      apiBaseUrl: apiBaseUrl,
      sessionToken: sessionToken,
    );
  }

  Future<String> _rewriteRemotely({
    required String text,
    required String mode,
    required String context,
    required String? apiBaseUrl,
    required String? sessionToken,
  }) async {
    final apiBase = (apiBaseUrl ?? AppConfig.apiBaseUrl).trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final token = (sessionToken ?? AppConfig.appSessionToken).trim();
    if (apiBase.isEmpty || token.isEmpty) {
      throw Exception(
        'La reformulation nécessite une connexion à votre session.',
      );
    }

    final response = await _client
        .post(
          Uri.parse('$apiBase/api/ai/rewrite'),
          headers: {'Content-Type': 'application/json', 'X-App-Session': token},
          body: jsonEncode({
            'text': text,
            'mode': _normalizeMode(mode),
            'context': context,
          }),
        )
        .timeout(const Duration(seconds: 65));

    if (response.statusCode == 401) {
      await AppConfig.notifyUnauthorized();
    }

    dynamic payload;
    try {
      payload = jsonDecode(response.body);
    } catch (_) {
      payload = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverError = payload is Map && payload['error'] is String
          ? (payload['error'] as String).trim()
          : '';
      throw Exception(
        serverError.isNotEmpty
            ? serverError
            : 'Reformulation impossible (${response.statusCode}).',
      );
    }

    final data = payload is Map ? payload['data'] : null;
    final rewrittenText = data is Map
        ? data['text']?.toString().trim() ?? ''
        : '';
    if (rewrittenText.isEmpty) {
      throw Exception("L'IA n'a renvoyé aucun texte.");
    }
    return rewrittenText;
  }

  String _normalizeMode(String mode) {
    return const {'professional', 'concise', 'correct'}.contains(mode)
        ? mode
        : 'professional';
  }
}
