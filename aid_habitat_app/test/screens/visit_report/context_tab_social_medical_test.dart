import 'dart:convert';
import 'dart:io';

import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/context_tab.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _ContextRepository extends Fake implements DossierRepository {
  @override
  Future<Map<String, dynamic>?> fetchContexteDeVie(String dossierId) async => {
    'medicalContext': const MedicalContext().toJson(),
    'autonomy': const AutonomyData().toJson(),
  };
}

class _MedicalHarness extends StatefulWidget {
  const _MedicalHarness({required this.dossier});

  final Dossier dossier;

  @override
  State<_MedicalHarness> createState() => _MedicalHarnessState();
}

class _MedicalHarnessState extends State<_MedicalHarness> {
  Set<int> flags = <int>{};
  int editRevision = 0;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Row(
        children: [
          Expanded(
            child: ContextTab(
              dossier: widget.dossier,
              repository: _ContextRepository(),
              currentMedicalFlags: flags,
              onMedicalFlagToggled: (number, checked) async {
                setState(() {
                  flags = {...flags};
                  if (checked) {
                    flags.add(number);
                  } else {
                    flags.remove(number);
                  }
                  editRevision += 1;
                });
              },
            ),
          ),
          SizedBox(
            width: 650,
            child: NotesWidget(
              patientId: widget.dossier.patient.id,
              dossierId: widget.dossier.id,
              tabKey: 'Contexte de vie-Médical',
              medicalFlags: flags,
              medicalFlagsScopeKey: 'occupant_0',
              medicalFlagsUserEditRevision: editRevision,
              onMedicalFlagsChanged: (loaded) {
                if (!setEquals(flags, loaded)) {
                  setState(() => flags = {...loaded});
                }
              },
            ),
          ),
        ],
      ),
    ),
  );
}

Dossier _fictionalDossier() => Dossier(
  id: 'dossier-social-fictif',
  patient: Patient(
    id: 'patient-social-fictif',
    firstName: 'Camille',
    lastName: 'FICTIF',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.IN_PROGRESS,
  ergoId: 'ergo-fictif',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: const {},
  createdAt: '2026-10-05',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  testWidgets('the fourth medical checkbox toggles flag 4 after reopening', (
    tester,
  ) async {
    final events = <(int, bool)>[];
    final repository = _ContextRepository();
    final dossier = _fictionalDossier();

    Widget screen(Set<int> flags) => MaterialApp(
      home: Scaffold(
        body: ContextTab(
          dossier: dossier,
          repository: repository,
          currentMedicalFlags: flags,
          onMedicalFlagToggled: (number, checked) async {
            events.add((number, checked));
          },
        ),
      ),
    );

    await tester.pumpWidget(screen({1, 2, 3}));
    await tester.pumpAndSettle();
    expect(find.text('Environnement social'), findsOneWidget);
    await tester.ensureVisible(find.text('Environnement social'));
    await tester.tap(find.text('Environnement social'));
    expect(events, [(4, true)]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(screen({1, 2, 3, 4}));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Environnement social'));
    await tester.tap(find.text('Environnement social'));
    expect(events, [(4, true), (4, false)]);
  });

  test('offline notes keep old text, flags and other occupant/page', () async {
    final database = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
    );
    addTearDown(database.close);
    final local = LocalDatabase.forTesting(database);
    await local.createSchemaForTesting();
    final notes = NoteRepository(database: local);
    const patientId = 'patient-social-fictif';
    const dossierId = 'dossier-social-fictif';
    const tabKey = 'Contexte de vie-Médical';

    Future<void> save(int page, Map<String, dynamic> drawing) =>
        notes.saveDrawingJson(
          patientId: patientId,
          dossierId: dossierId,
          tabKey: tabKey,
          pageNumber: page,
          drawingJson: jsonEncode(drawing),
          mutationOrigin: SyncMutationOrigin.userEdit,
        );

    final oldPage = <String, dynamic>{
      'version': 1,
      'text': 'Ancienne note médicale fictive',
      'strokes': <dynamic>[],
      'medicalFlags': [1, 2, 3],
      'medicalFlagsByScope': {
        'occupant_0': [1, 2, 3],
        'occupant_1': [3],
      },
    };
    final otherPage = <String, dynamic>{
      'version': 1,
      'text': 'Deuxième page ancienne',
      'strokes': <dynamic>[],
      'medicalFlagsByScope': {
        'occupant_0': [2],
      },
    };
    await save(0, oldPage);
    await save(1, otherPage);

    final reopened = NoteRepository(database: local);
    final loaded =
        jsonDecode(
              (await reopened.fetchDrawingJson(
                patientId: patientId,
                dossierId: dossierId,
                tabKey: tabKey,
                pageNumber: 0,
              ))!,
            )
            as Map<String, dynamic>;
    final scopes = Map<String, dynamic>.from(
      loaded['medicalFlagsByScope'] as Map,
    );
    scopes['occupant_1'] = [3, 4];
    loaded['medicalFlagsByScope'] = scopes;
    await save(0, loaded);

    final afterCheck =
        jsonDecode(
              (await NoteRepository(database: local).fetchDrawingJson(
                patientId: patientId,
                dossierId: dossierId,
                tabKey: tabKey,
                pageNumber: 0,
              ))!,
            )
            as Map<String, dynamic>;
    expect(afterCheck['text'], oldPage['text']);
    expect(afterCheck['strokes'], oldPage['strokes']);
    expect(afterCheck['medicalFlags'], [1, 2, 3]);
    expect((afterCheck['medicalFlagsByScope'] as Map)['occupant_0'], [1, 2, 3]);
    expect((afterCheck['medicalFlagsByScope'] as Map)['occupant_1'], [3, 4]);
    expect(
      jsonDecode(
        (await reopened.fetchDrawingJson(
          patientId: patientId,
          dossierId: dossierId,
          tabKey: tabKey,
          pageNumber: 1,
        ))!,
      ),
      otherPage,
    );

    (afterCheck['medicalFlagsByScope'] as Map)['occupant_1'] = [3];
    await save(0, afterCheck);
    final afterUncheck =
        jsonDecode(
              (await NoteRepository(database: local).fetchDrawingJson(
                patientId: patientId,
                dossierId: dossierId,
                tabKey: tabKey,
                pageNumber: 0,
              ))!,
            )
            as Map<String, dynamic>;
    expect(afterUncheck, oldPage);
  });

  testWidgets('a real NotesWidget saves flag 4 and reloads it offline', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previousPlatform = debugDefaultTargetPlatformOverride;
    final previousApiBaseUrl = AppConfig.apiBaseUrl;
    final previousSession = AppConfig.appSessionToken;
    late Directory temporaryDatabaseDirectory;
    late NoteRepository notes;
    const patientId = 'patient-social-fictif';
    const dossierId = 'dossier-social-fictif';
    const tabKey = 'Contexte de vie-Médical';

    await tester.runAsync(() async {
      temporaryDatabaseDirectory = await Directory.systemTemp.createTemp(
        'app-ergo-social-medical-',
      );
      databaseFactory = databaseFactoryFfi;
      await databaseFactoryFfi.setDatabasesPath(
        temporaryDatabaseDirectory.path,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      AppConfig.setApiBaseUrl('');
      AppConfig.clearAppSessionToken();
      notes = NoteRepository();
      await notes.saveDrawingJson(
        patientId: patientId,
        dossierId: dossierId,
        tabKey: tabKey,
        drawingJson: jsonEncode({
          'version': 1,
          'text': 'Ancienne note réelle fictive',
          'strokes': <dynamic>[],
          'medicalFlags': [1, 2, 3],
          'medicalFlagsByScope': {
            'occupant_0': [1, 2, 3],
            'occupant_1': [3],
          },
        }),
        mutationOrigin: SyncMutationOrigin.userEdit,
      );
    });
    addTearDown(() async {
      await (await LocalDatabase.instance.database).close();
      await temporaryDatabaseDirectory.delete(recursive: true);
      debugDefaultTargetPlatformOverride = previousPlatform;
      AppConfig.setApiBaseUrl(previousApiBaseUrl);
      AppConfig.setAppSessionToken(previousSession);
    });

    await tester.pumpWidget(_MedicalHarness(dossier: _fictionalDossier()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.text('Ancienne note réelle fictive'), findsOneWidget);
    await tester.ensureVisible(find.text('Environnement social'));
    await tester.tap(find.text('Environnement social'));
    await tester.pump();
    expect(
      tester.state<_MedicalHarnessState>(find.byType(_MedicalHarness)).flags,
      {1, 2, 3, 4},
    );

    Future<Map<String, dynamic>> stored() async =>
        jsonDecode(
              (await notes.fetchDrawingJson(
                patientId: patientId,
                dossierId: dossierId,
                tabKey: tabKey,
              ))!,
            )
            as Map<String, dynamic>;
    Future<Map<String, dynamic>> waitForFlag4(bool expected) async {
      for (var attempt = 0; attempt < 40; attempt++) {
        await tester.pump(const Duration(milliseconds: 25));
        final current = (await tester.runAsync(stored))!;
        final scopes = current['medicalFlagsByScope'] as Map;
        if ((scopes['occupant_0'] as List).contains(4) == expected) {
          return current;
        }
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        });
      }
      throw StateError('Flag 4 state $expected was not saved by NotesWidget');
    }

    final checked = await waitForFlag4(true);
    expect(checked['text'], 'Ancienne note réelle fictive');
    expect(checked['medicalFlags'], [1, 2, 3, 4]);
    expect((checked['medicalFlagsByScope'] as Map)['occupant_0'], [1, 2, 3, 4]);
    expect((checked['medicalFlagsByScope'] as Map)['occupant_1'], [3]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_MedicalHarness(dossier: _fictionalDossier()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.ensureVisible(find.text('Environnement social'));
    await tester.tap(find.text('Environnement social'));
    await tester.pump();
    final unchecked = await waitForFlag4(false);
    expect(unchecked['text'], 'Ancienne note réelle fictive');
    expect(unchecked['medicalFlags'], [1, 2, 3]);
    expect((unchecked['medicalFlagsByScope'] as Map)['occupant_0'], [1, 2, 3]);
    expect((unchecked['medicalFlagsByScope'] as Map)['occupant_1'], [3]);
    debugDefaultTargetPlatformOverride = previousPlatform;
  });
}
