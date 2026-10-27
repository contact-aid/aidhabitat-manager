// Isolated device preview. Build only with the visitaitest bundle identifier.
// No production account or OpenRouter credential is embedded.
// A scoped LAN-only preview session is enabled only by an explicit tap.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/components/visit_recording_button.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/visit_assistant_service.dart';
import 'package:aid_habitat_app/services/visit_assistant_store.dart';
import 'package:aid_habitat_app/screens/visit_report/transcript_tab.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final package = await PackageInfo.fromPlatform();
  if (package.packageName != 'com.aidhabitat.manager.visitaitest') {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              'Cette recette exige l’application Ergo IA Test séparée.',
            ),
          ),
        ),
      ),
    );
    return;
  }
  AppConfig.setApiBaseUrl('');
  AppConfig.clearAppSessionToken();
  final db = await LocalDatabase.instance.database;
  final now = DateTime.now().toIso8601String();
  await db.insert('app_users', {
    'local_id': 'visit-test-user',
    'email': 'visit-test@example.invalid',
    'display_name': 'Profil fictif',
    'role': 'ergo',
    'password_salt': 'not-a-login',
    'password_hash': 'not-a-login',
    'ergo_label': 'Test',
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
  await db.insert('app_session', {
    'id': 1,
    'user_local_id': 'visit-test-user',
    'created_at': now,
    'updated_at': now,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  await ConnectivityService().initialize();
  VisitAssistantService.instance.contextLoader = (dossierId, patientId) =>
      VisitAssistantService.instance.collectNoteContext(
        patientId: patientId,
        dossierId: dossierId,
      );
  VisitAssistantService.instance.initialize();
  runApp(const _PreviewApp());
}

class _DemoPatient implements Patient {
  @override
  String get id => 'visit-test-patient';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DemoDossier implements Dossier {
  @override
  String get id => 'visit-test-dossier';
  @override
  Patient get patient => _DemoPatient();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PreviewApp extends StatefulWidget {
  const _PreviewApp();
  @override
  State<_PreviewApp> createState() => _PreviewAppState();
}

class _PreviewAppState extends State<_PreviewApp> {
  static const _url = String.fromEnvironment('VISIT_PREVIEW_URL');
  static const _token = String.fromEnvironment('VISIT_PREVIEW_TOKEN');
  final _service = VisitAssistantService.instance;
  bool _sending = false;
  bool _enabled = false;
  String? _error;
  String _section = 'Accessibilité-Notes';
  static const _sections = {
    'Accessibilité-Notes': 'Accès',
    'Bénéficiaire-Notes': 'Bénéficiaire',
    'Contexte de vie-Médical': 'Environnement',
    'Contexte de vie-Autonomie': 'Habitudes de vie',
    'Sanitaires-Notes': 'Salle de bain et WC',
    'Préconisations-Projet': 'Projet',
    'Préconisations-Résumé': 'Résumé',
  };

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      if (_url.isEmpty || _token.isEmpty) {
        throw StateError('La connexion de recette n’est pas configurée.');
      }
      final response = await http
          .get(Uri.parse('$_url/api/preview-health'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw StateError('API de test indisponible.');
      }
      final context = await _service.collectNoteContext(
        patientId: 'visit-test-patient',
        dossierId: 'visit-test-dossier',
      );
      final store = VisitAssistantStore();
      for (final job in await store.list(
        'visit-test@example.invalid',
        dossierId: 'visit-test-dossier',
      )) {
        if (job['context'] == null && job['status'] == 'pending') {
          job['context'] = context;
          await store.save(job);
        }
      }
      AppConfig.setApiBaseUrl(_url);
      AppConfig.setAppSessionToken(_token);
      if (!AppConfig.hasRemoteConfig) {
        throw StateError('Adresse de test refusée.');
      }
      setState(() => _enabled = true);
      unawaited(_service.pump());
    } catch (_) {
      setState(
        () => _error =
            'Connexion impossible. Garde le Mac allumé et l’iPad sur le même Wi-Fi, puis réessaie. Aucun audio n’est supprimé.',
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ergo IA Test',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff675078),
      useMaterial3: true,
    ),
    home: DefaultTabController(
      length: 2,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Visite fictive',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    VisitRecordingButton(dossier: _DemoDossier()),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _enabled
                      ? 'Recette connectée à l’API de test du Mac. Les enregistrements fictifs sont traités via OpenRouter.'
                      : 'Aucun envoi avant ton appui sur « Traiter les enregistrements fictifs ». Utilise uniquement des situations fictives.',
                ),
                if (_error != null)
                  Text(
                    _error!,
                    style: const TextStyle(color: Colors.deepOrange),
                  ),
                const TabBar(
                  tabs: [
                    Tab(text: 'Rubriques et notes'),
                    Tab(text: 'Transcription et IA'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      Column(
                        children: [
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: _sections.entries
                                  .map(
                                    (entry) => Padding(
                                      padding: const EdgeInsets.only(
                                        right: 6,
                                        top: 8,
                                      ),
                                      child: ChoiceChip(
                                        label: Text(entry.value),
                                        selected: _section == entry.key,
                                        onSelected: (_) => setState(
                                          () => _section = entry.key,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          ),
                          Expanded(
                            child: Card(
                              child: NotesWidget(
                                key: ValueKey(_section),
                                patientId: 'visit-test-patient',
                                dossierId: 'visit-test-dossier',
                                tabKey: _section,
                                title: _sections[_section]!,
                                showCanvas: true,
                                allowPagination: false,
                                showSaveButton: false,
                                sharedText: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const VisitTranscriptTab(dossierId: 'visit-test-dossier'),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                ListenableBuilder(
                  listenable: _service,
                  builder: (_, _) => FilledButton(
                    onPressed: _sending || _service.isRecording ? null : _send,
                    child: Text(
                      _sending
                          ? 'Connexion au test…'
                          : _enabled
                          ? 'Reprendre le traitement'
                          : 'Traiter les enregistrements fictifs',
                    ),
                  ),
                ),
                ListenableBuilder(
                  listenable: _service,
                  builder: (_, _) {
                    final complete = _service.jobs
                        .where((j) => j['status'] == 'complete')
                        .length;
                    final retained = _service.jobs
                        .where(
                          (j) =>
                              j['status'] != 'empty' &&
                              j['status'] != 'start_failed',
                        )
                        .length;
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _service.error ??
                            (_service.isRecording
                                ? 'Enregistrement : ${_service.duration.toInt()} secondes.'
                                : '$retained enregistrement(s) conservé(s), $complete rédaction(s) terminée(s).'),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
