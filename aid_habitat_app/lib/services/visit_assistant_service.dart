import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import '../components/notes_canvas_painters.dart';
import '../models/types.dart';
import 'app_config.dart';
import 'auth_service.dart';
import 'connectivity_service.dart';
import 'data_service.dart';
import 'note_repository.dart';
import 'dossier_repository.dart';
import 'visit_assistant_store.dart';

class VisitAssistantConfig {
  static const enabled = bool.fromEnvironment(
    'AIDHABITAT_VISIT_ASSISTANT',
    defaultValue: false,
  );
  static bool get canRecord =>
      enabled && !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
}

class VisitAssistantService extends ChangeNotifier with WidgetsBindingObserver {
  VisitAssistantService._();
  static final instance = VisitAssistantService._();
  static const _channel = MethodChannel('aidhabitat/visit_recorder');
  final _store = VisitAssistantStore();
  final _notes = NoteRepository();
  final _client = http.Client();
  Timer? _syncTimer;
  Timer? _meterTimer;
  StreamSubscription<bool>? _connectivity;
  bool _busy = false;
  bool _meterBusy = false;
  bool _starting = false;
  Map<String, dynamic>? _recording;
  List<Map<String, dynamic>> jobs = [];
  double level = 0;
  final List<double> voiceLevels = List<double>.filled(4, 0);
  double duration = 0;
  String? error;
  String? get recordingDossierId => _recording?['dossierId'] as String?;
  bool get isRecording => _recording != null;
  bool get isStarting => _starting;

  void initialize() {
    if (!VisitAssistantConfig.enabled || _syncTimer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _syncTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(pump()),
    );
    _connectivity = ConnectivityService().offlineStream.listen((offline) {
      if (!offline) unawaited(pump());
    });
    unawaited(pump());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(pump());
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _meterTimer?.cancel();
    _connectivity?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _client.close();
    super.dispose();
  }

  Future<String?> _owner() async =>
      (await AuthService().getCurrentUser())?.email.toLowerCase();
  void _checkSession(int epoch) {
    if (AppConfig.sessionEpoch != epoch || !AppConfig.hasRemoteConfig) {
      throw StateError('Session modifiée. Les données sont conservées.');
    }
  }

  Future<void> start(Dossier dossier) async {
    if (!VisitAssistantConfig.canRecord || isRecording || _starting) return;
    _starting = true;
    error = null;
    notifyListeners();
    Map<String, dynamic>? reserved;
    try {
      final owner = await _owner();
      if (owner == null) {
        throw StateError('Connecte-toi avant de commencer une visite.');
      }
      final id = List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final job = <String, dynamic>{
        'id': id,
        'owner': owner,
        'dossierId': dossier.id,
        'patientId': dossier.patient.id,
        'status': 'recording',
        'segments': [],
        'createdAt': DateTime.now().toIso8601String(),
      };
      // Reserve the durable identity before opening the microphone.
      reserved = job;
      await _store.save(job);
      final state = Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('start', {'id': id}) ??
            {},
      );
      if (state['active'] != true) {
        throw StateError('Le microphone n’a pas démarré.');
      }
      _recording = job;
      voiceLevels.fillRange(0, 4, 0);
      duration = 0;
      _meterTimer?.cancel();
      _meterTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => unawaited(_meter()),
      );
    } catch (e) {
      if (reserved != null) {
        reserved['status'] = 'start_failed';
        await _store.save(reserved);
      }
      error = _message(e);
      rethrow;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _meter() async {
    if (_meterBusy || _recording == null) return;
    _meterBusy = true;
    try {
      final state =
          await _channel.invokeMapMethod<String, dynamic>('status') ?? {};
      level = (state['level'] as num?)?.toDouble() ?? 0;
      voiceLevels.removeAt(0);
      voiceLevels.add(level);
      duration = (state['duration'] as num?)?.toDouble() ?? 0;
      if (state['active'] != true) {
        await stop(interrupted: state['interrupted'] == true);
      }
      notifyListeners();
    } catch (_) {
      error = 'Vérifie le microphone : son état n’est plus disponible.';
      notifyListeners();
    } finally {
      _meterBusy = false;
    }
  }

  Future<void> stop({bool interrupted = false}) async {
    final job = _recording;
    if (job == null) return;
    _meterTimer?.cancel();
    final state = await _channel.invokeMapMethod<String, dynamic>('stop') ?? {};
    job['segments'] = state['segments'] ?? [];
    job['interrupted'] = interrupted;
    job['status'] = (job['segments'] as List).isEmpty ? 'empty' : 'pending';
    await _store.save(job);
    _recording = null;
    level = 0;
    notifyListeners();
    unawaited(pump());
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String route, {
    Object? body,
    Uint8List? bytes,
    Map<String, String>? extraHeaders,
  }) async {
    final epoch = AppConfig.sessionEpoch;
    _checkSession(epoch);
    final request = http.Request(
      method,
      Uri.parse('${AppConfig.apiBaseUrl}/api/visit-assistant/$route'),
    );
    request.headers.addAll({
      'X-App-Session': AppConfig.appSessionToken,
      'Content-Type': bytes == null
          ? 'application/json'
          : 'application/octet-stream',
      ...?extraHeaders,
    });
    if (bytes != null) {
      request.bodyBytes = bytes;
    } else if (body != null) {
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 170)),
    ).timeout(const Duration(seconds: 170));
    _checkSession(epoch);
    if (response.statusCode == 401) {
      await AppConfig.notifyUnauthorized();
      throw StateError('Reconnecte-toi pour poursuivre le traitement.');
    }
    if (response.statusCode >= 400) {
      String message = 'Traitement en attente. Les sources sont conservées.';
      try {
        message =
            (jsonDecode(response.body) as Map)['error']?.toString() ?? message;
      } catch (_) {}
      throw StateError(message);
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    return decoded;
  }

  Future<void> pump() async {
    if (!VisitAssistantConfig.enabled || _busy) return;
    _busy = true;
    try {
      final owner = await _owner();
      if (_recording != null && _recording!['owner'] != owner) {
        await stop(interrupted: true);
      }
      if (owner == null) {
        jobs = [];
        return;
      }
      jobs = await _store.list(owner);
      // Recover interrupted native captures after an app/process restart.
      for (final job in jobs.where(
        (j) => j['status'] == 'recording' && j['id'] != _recording?['id'],
      )) {
        if (!VisitAssistantConfig.canRecord) continue;
        try {
          final state =
              await _channel.invokeMapMethod<String, dynamic>('recover', {
                'id': job['id'],
              }) ??
              {};
          if (state['active'] == true && state['id'] == job['id']) {
            _recording = job;
            _meterTimer?.cancel();
            _meterTimer = Timer.periodic(
              const Duration(milliseconds: 100),
              (_) => unawaited(_meter()),
            );
            continue;
          }
          job['segments'] = state['segments'] ?? [];
          job['interrupted'] = true;
          job['status'] = (job['segments'] as List).isEmpty
              ? 'empty'
              : 'pending';
        } catch (_) {
          job['status'] = 'recovery_required';
          job['error'] =
              'Un enregistrement interrompu nécessite une vérification. Les fichiers audio sont conservés.';
        }
        await _store.save(job);
      }
      if (ConnectivityService().isOffline || !AppConfig.hasRemoteConfig) return;
      final epoch = AppConfig.sessionEpoch;
      for (final job in jobs.where(
        (j) => ['pending', 'uploading', 'processing'].contains(j['status']),
      )) {
        _checkSession(epoch);
        if (job['context'] == null) {
          final dossier = await DataService().fetchDossierById(
            job['dossierId'] as String,
          );
          if (dossier == null) {
            throw StateError('Le dossier local n’est pas disponible.');
          }
          job['context'] = await _context(dossier);
          await _store.save(job);
        }
        final base =
            '${Uri.encodeComponent(job['dossierId'] as String)}/${job['id']}';
        if (job['status'] != 'processing') {
          await _request('PUT', base, body: {'context': job['context']});
          job['status'] = 'uploading';
          final segments = job['segments'] as List;
          for (
            var i = (job['uploaded'] as int? ?? 0);
            i < segments.length;
            i++
          ) {
            _checkSession(epoch);
            final segment = segments[i] as Map;
            final bytes = await _channel.invokeMethod<Uint8List>('read', {
              'id': job['id'],
              'name': segment['name'],
            });
            if (bytes == null) throw StateError('Extrait audio introuvable.');
            await _request(
              'PUT',
              '$base/chunks/$i',
              bytes: bytes,
              extraHeaders: {
                'X-Audio-Sha256': sha256.convert(bytes).toString(),
                'X-Audio-Duration': '${segment['duration']}',
              },
            );
            job['uploaded'] = i + 1;
            await _store.save(job);
            notifyListeners();
          }
          await _request(
            'POST',
            '$base/finish',
            body: {'chunkCount': segments.length},
          );
          job['status'] = 'processing';
          await _store.save(job);
        }
        final remote = (await _request('POST', '$base/process'))['data'] as Map;
        job['remote'] = remote;
        if (remote['status'] == 'complete') {
          final result = Map<String, dynamic>.from(remote['result'] as Map);
          final sections = Map<String, dynamic>.from(result['sections'] as Map);
          for (final section in sections.entries) {
            _checkSession(epoch);
            await _notes.appendVisitText(
              patientId: job['patientId'] as String,
              dossierId: job['dossierId'] as String,
              tabKey: section.key,
              recordingId: job['id'] as String,
              text: section.value.toString(),
            );
          }
          job['status'] = 'complete';
        }
        job.remove('error');
        await _store.save(job);
      }
      error = null;
    } catch (e) {
      error = _message(e);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _context(Dossier dossier) async {
    const keys = [
      'Bénéficiaire-Notes',
      'Contexte de vie-Médical',
      'Contexte de vie-Autonomie',
      'Accessibilité-Notes',
      'Sanitaires-Notes',
      'Sanitaires-Salle de bain-Manuscrit',
      'Sanitaires-WC-Manuscrit',
      'Préconisations-Projet',
      'Préconisations-Résumé',
      'Résumé',
    ];
    final text = <String, List<String>>{};
    final handwriting = <Map<String, dynamic>>[];
    for (final key in keys) {
      final pages = await _notes.fetchLocalNotePages(
        patientId: dossier.patient.id,
        dossierId: dossier.id,
        tabKey: key,
      );
      for (final page in pages) {
        final drawing = page.drawingJson.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(page.drawingJson) as Map<String, dynamic>;
        if (drawing['deleted'] == true) continue;
        final content = drawing['text']?.toString() ?? page.textContent;
        if (content.isNotEmpty) (text[key] ??= []).add(content);
        final strokes = (drawing['strokes'] as List? ?? [])
            .whereType<Map>()
            .map((s) => Stroke.fromJson(Map<String, dynamic>.from(s)))
            .whereType<Stroke>()
            .toList();
        if (strokes.isEmpty) continue;
        if (handwriting.length >= 30) {
          throw StateError(
            'Plus de 30 pages manuscrites : une préparation spécifique est nécessaire. L’audio reste conservé.',
          );
        }
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        const size = ui.Size(900, 1200);
        canvas.drawRect(
          ui.Offset.zero & size,
          ui.Paint()..color = const ui.Color(0xffffffff),
        );
        StrokePainter(strokes: strokes, activeStroke: null).paint(canvas, size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(900, 1200);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        if (data != null) {
          handwriting.add({
            'section': key,
            'page': page.pageNumber,
            'image':
                'data:image/png;base64,${base64Encode(data.buffer.asUint8List())}',
          });
        }
      }
    }
    final repository = DossierRepository();
    final medical = await repository.fetchContexteDeVie(dossier.id);
    final sanitary = await repository.fetchDiagnosticSanitaire(dossier.id);
    final recommendations = await repository.fetchVisitRecommendations(
      dossier.id,
    );
    final observations = await repository.fetchObservations(dossier.id);
    // An unchecked field is not a clinically confirmed absence. Strip
    // default false/empty values, identity keys and contact identifiers.
    dynamic relevant(dynamic value) {
      if (value is Map) {
        if (value.containsKey('checked') && value['checked'] != true) {
          return null;
        }
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          if ([
            'id',
            'dossierId',
            'housingRoomId',
            'firstName',
            'lastName',
            'birthDate',
            'phone',
            'email',
            'numeroSecuriteSociale',
          ].contains(entry.key)) {
            continue;
          }
          final filtered = relevant(entry.value);
          if (filtered != null) result[entry.key.toString()] = filtered;
        }
        return result.isEmpty ? null : result;
      }
      if (value is List) {
        final result = value.map(relevant).where((v) => v != null).toList();
        return result.isEmpty ? null : result;
      }
      if (value == false || value == null || value == '') return null;
      return value;
    }

    return {
      'existingText': text,
      'handwritten': handwriting,
      'medicalAndAutonomy': relevant(medical),
      'sanitary': relevant(sanitary?.toJson()),
      'retainedRecommendations': recommendations
          .map((r) => {'title': r.displayTitle, 'note': r.note})
          .toList(),
      'observations': observations == null
          ? null
          : {
              'equipment': observations.observationEquipements,
              'project': observations.projetSouhaitUsage,
              'summary': observations.resumePreconisations,
            },
      'profile': {
        'householdSize': dossier.patient.numberPeople,
        'visitDate': dossier.visitDate,
        'familySituation': dossier.patient.familySituation,
        'occupationStatus': dossier.patient.occupationStatus,
        'housingType': dossier.housing.typology,
        'levels': dossier.housing.levels,
        'occupants': dossier.patient.occupants
            .map(
              (o) => {
                'gender': o.gender,
                'homeHelp': o.homeHelpTxt,
                'mobilityAids': o.dependenceTxt,
                'apaGir': o.apaGir,
              },
            )
            .toList(),
      },
    };
  }

  Future<List<Map<String, dynamic>>> loadTranscripts(String dossierId) async {
    if (!AppConfig.hasRemoteConfig || ConnectivityService().isOffline) {
      final owner = await _owner();
      if (owner == null) return [];
      return (await _store.list(owner, dossierId: dossierId))
          .map((j) => Map<String, dynamic>.from(j['remote'] as Map? ?? j))
          .toList();
    }
    return ((await _request('GET', Uri.encodeComponent(dossierId)))['data']
            as List)
        .map((j) => Map<String, dynamic>.from(j as Map))
        .toList();
  }

  Future<Map<String, dynamic>> ask(
    String dossierId,
    String id,
    String question,
  ) async => Map<String, dynamic>.from(
    (await _request(
          'POST',
          '${Uri.encodeComponent(dossierId)}/$id/chat',
          body: {'question': question},
        ))['data']
        as Map,
  );

  static String _message(Object error) => error is PlatformException
      ? error.message ?? 'Microphone indisponible.'
      : error is StateError
      ? error.message.toString()
      : 'Traitement interrompu. Les sources sont conservées ; une reprise sera tentée.';
}
