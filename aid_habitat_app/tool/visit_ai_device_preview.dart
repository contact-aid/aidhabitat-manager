// Isolated device preview. Build only with the visitaitest bundle identifier.
// No API credentials, production account or network upload is used here.
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/components/visit_recording_button.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:aid_habitat_app/services/visit_assistant_service.dart';

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

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ergo IA Test',
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff675078),
      useMaterial3: true,
    ),
    home: Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
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
              const SizedBox(height: 12),
              const Text(
                'Recette sur iPad : microphone, mode avion, verrouillage de l’écran et retour dans l’app.\n'
                'L’audio reste sur cet iPad. Aucun envoi réseau. Le bouton ci-dessous simule seulement l’ajout d’un texte.',
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Card(
                  child: NotesWidget(
                    patientId: 'visit-test-patient',
                    dossierId: 'visit-test-dossier',
                    tabKey: 'Accessibilité-Notes',
                    title: 'Observation test',
                    showCanvas: false,
                    allowPagination: false,
                    showSaveButton: false,
                    sharedText: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () async {
                  await NoteRepository().appendVisitText(
                    patientId: 'visit-test-patient',
                    dossierId: 'visit-test-dossier',
                    tabKey: 'Accessibilité-Notes',
                    recordingId: 'synthetic-insertion',
                    text:
                        'Ajout fictif : une marche de 12 cm est relevée à l’entrée.',
                  );
                },
                child: const Text(
                  'Simuler un ajout IA, sans écraser la saisie',
                ),
              ),
              ListenableBuilder(
                listenable: VisitAssistantService.instance,
                builder: (_, _) {
                  final service = VisitAssistantService.instance;
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      service.error ??
                          (service.isRecording
                              ? 'Enregistrement en cours : ${service.duration.toInt()} secondes.'
                              : '${service.jobs.where((j) => j['status'] == 'pending').length} enregistrement(s) conservé(s) localement.'),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
