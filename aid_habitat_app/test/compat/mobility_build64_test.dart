// Also executed unchanged against the exact installed build 64 by
// tools/compat/test-mobility-build64.sh. No new mobility parser is imported.
import 'dart:convert';

import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/beneficiary_tab.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/nocodb_api_client.dart';
import 'package:aid_habitat_app/services/nocodb_sync_service.dart';
import 'package:aid_habitat_app/services/sync_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _version = '2026-09-01T10:00:00.000Z';
const _multiple = 'Canne, Déambulateur, Orthèse spéciale';

Map<String, dynamic> _payload(String aids) => {
  'id': 'mobility-dossier',
  'createdAt': _version,
  'updatedAt': _version,
  'workspaceUpdatedAt': _version,
  'patient': <String, dynamic>{
    'id': 'mobility-patient',
    'firstName': 'Anne',
    'lastName': 'FICTIVE',
    'dependenceTxt': aids,
    'homeHelp': true,
    'homeHelpTxt': 'Avant',
    'occupants': [
      Occupant(
        firstName: 'Anne',
        lastName: 'FICTIVE',
        dependenceTxt: aids,
        homeHelp: true,
        homeHelpTxt: 'Avant',
      ).toJson(),
    ],
    'updatedAt': _version,
  },
  'housing': {'updatedAt': _version},
};

class _Repository extends Fake implements DossierRepository {
  final writes = <Map<String, dynamic>>[];
  @override
  Future<void> updatePatient(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) async => writes.add(Map.of(fields));
}

Dossier _dossier(String aids) => Dossier(
  id: 'mobility-dossier',
  patient: Patient(
    id: 'mobility-patient',
    firstName: 'Anne',
    lastName: 'FICTIVE',
    birthDate: '',
    phone: '',
    email: '',
    address: '',
    city: '',
    zipCode: '',
    familySituation: '',
    incomeCategory: '',
    dependenceTxt: aids,
    occupants: [
      Occupant(
        firstName: 'Anne',
        lastName: 'FICTIVE',
        dependenceTxt: aids,
        homeHelp: true,
        homeHelpTxt: 'Avant',
      ),
    ],
    trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
  ),
  status: DossierStatus.IN_PROGRESS,
  ergoId: 'synthetic-ergo',
  housing: Housing(
    type: HousingType.HOUSE,
    heating: HeatingMode.ELECTRIC,
    accessibilityNotes: '',
  ),
  autonomyNotes: '',
  plans: {},
  createdAt: _version,
);

Future<void> _connectivity(bool online) async {
  ConnectivityService().dispose();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (_) async => [online ? 'wifi' : 'none'],
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    (_) async => null,
  );
  await ConnectivityService().initialize();
}

void main() {
  const legacyBuild64 = bool.fromEnvironment('LEGACY_BUILD64');
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  for (final aids in ['Canne', _multiple, 'Orthèse spéciale', '']) {
    testWidgets('legacy UI read/other-field save preserves "$aids"', (
      tester,
    ) async {
      final repository = _Repository();
      final controller = BeneficiaryTabController();
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeneficiaryTab(
              dossier: _dossier(aids),
              repository: repository,
              controller: controller,
              initialSubSection: 2,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(controller.flushPendingSave);
      expect(repository.writes, isEmpty);
      if (!legacyBuild64) {
        expect(find.text('Dépendance'), findsNothing);
        final detail = tester.widget<FormTextField>(
          find.byWidgetPredicate(
            (w) => w is FormTextField && w.label == 'Détails',
          ),
        );
        detail.onChanged!('Après');
        await tester.pump();
        await tester.runAsync(controller.flushPendingSave);
        expect(repository.writes, hasLength(1));
        final write = repository.writes.single;
        expect(write.containsKey('dependence_txt'), isFalse);
        expect((jsonDecode(write['occupants_json'] as String) as List)
            .first['dependenceTxt'], aids);
        return;
      }
      final selector = tester.widget<FormToggleGroup>(
        find.byWidgetPredicate(
          (w) =>
              w is FormToggleGroup &&
              (legacyBuild64
                  ? w.label == 'Dépendance'
                  : w.options.length == 1 && w.options.single == 'Canne'),
        ),
      );
      expect(
        selector.selected,
        legacyBuild64
            ? aids
            : aids.split(', ').contains('Canne')
            ? 'Canne'
            : '',
      );
      final detail = tester.widget<FormTextField>(
        find.byWidgetPredicate(
          (w) => w is FormTextField && w.label == 'Détails',
        ),
      );
      detail.onChanged!('Après');
      await tester.pump();
      await tester.runAsync(controller.flushPendingSave);
      expect(repository.writes, hasLength(1));
      final write = repository.writes.single;
      expect(write.containsKey('dependence_txt'), isFalse);
      expect(
        (jsonDecode(write['occupants_json'] as String) as List)
            .first['dependenceTxt'],
        aids,
      );
    });
  }

  testWidgets(
    'KNOWN BLOCKER: build64 single-choice click replaces multiple aids',
    (tester) async {
      final repository = _Repository();
      final controller = BeneficiaryTabController();
      await tester.binding.setSurfaceSize(const Size(1200, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeneficiaryTab(
              dossier: _dossier(_multiple),
              repository: repository,
              controller: controller,
              initialSubSection: 2,
            ),
          ),
        ),
      );
      await tester.pump();
      if (!legacyBuild64) {
        expect(find.text('Dépendance'), findsNothing);
        expect(repository.writes, isEmpty);
        return;
      }
      final selector = tester.widget<FormToggleGroup>(
        find.byWidgetPredicate(
          (w) =>
              w is FormToggleGroup &&
              (legacyBuild64
                  ? w.label == 'Dépendance'
                  : w.options.length == 1 && w.options.single == 'Canne'),
        ),
      );
      expect(selector.options.contains(selector.selected), !legacyBuild64);
      await tester.tap(find.text('Canne'));
      await tester.pump();
      await tester.runAsync(controller.flushPendingSave);
      final expected = legacyBuild64
          ? 'Canne'
          : 'Déambulateur, Orthèse spéciale';
      expect(repository.writes.single['dependence_txt'], expected);
      expect(
        (jsonDecode(repository.writes.single['occupants_json'] as String)
                as List)
            .first['dependenceTxt'],
        expected,
      );
    },
  );

  for (final aids in ['Canne', _multiple, 'Orthèse spéciale', '']) {
    test(
      'offline/reconnect and web roundtrip preserve "$aids"; explicit clear survives',
      () async {
        AppConfig.setApiBaseUrl('https://synthetic.test');
        AppConfig.setAppSessionToken('synthetic-token');
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(() async {
          await db.close();
          ConnectivityService().dispose();
          AppConfig.setApiBaseUrl('');
          AppConfig.clearAppSessionToken();
        });
        final local = LocalDatabase.forTesting(db);
        await local.createSchemaForTesting();
        final repository = DossierRepository(database: local);
        final web = _payload(aids);
        final webPatient = web['patient'] as Map<String, dynamic>;
        await repository.mergeRemoteDossierPayloads([web]);
        final loaded = (await repository.fetchAllDossiers()).single;
        expect(loaded.patient.dependenceTxt, aids);
        expect(loaded.patient.occupants.first.dependenceTxt, aids);
        final occupant = loaded.patient.occupants.first.copyWith(
          homeHelpTxt: 'Après',
        );
        await _connectivity(false);
        await repository.updatePatient('mobility-patient', {
          'home_help_txt': 'Après',
          'occupants_json': jsonEncode([occupant.toJson()]),
        }, observedFields: loaded.patientEditBaseline);
        var requests = 0;
        final service = NocodbSyncService(
          database: local,
          syncRepository: SyncRepository.forTesting(database: local),
          apiClient: NocodbApiClient(
            client: MockClient((request) async {
              requests++;
              expect(request.method, 'PATCH');
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              final changes = Map<String, dynamic>.from(body)
                ..remove('concurrency')
                ..remove('expectedUpdatedAt');
              webPatient.addAll(changes);
              return http.Response(
                jsonEncode({
                  'data': {'updatedAt': _version},
                }),
                200,
              );
            }),
          ),
        );
        await service.pushPendingChanges();
        expect(requests, 0);
        expect((await db.query('sync_operations')).single['status'], 'pending');
        await _connectivity(true);
        expect((await service.pushPendingChanges()).pushedOperations, 1);
        expect(webPatient['dependenceTxt'], aids);
        expect((webPatient['occupants'] as List).first['dependenceTxt'], aids);
        await repository.mergeRemoteDossierPayloads([web]);
        final returned = (await repository.fetchAllDossiers()).single;
        expect(returned.patient.dependenceTxt, aids);
        expect(returned.patient.occupants.first.dependenceTxt, aids);
        if (aids.isNotEmpty) {
          await repository.updatePatient('mobility-patient', {
            'dependence_txt': '',
            'occupants_json': jsonEncode([
              returned.patient.occupants.first
                  .copyWith(dependenceTxt: '')
                  .toJson(),
            ]),
          });
          expect((await service.pushPendingChanges()).pushedOperations, 1);
          expect(webPatient['dependenceTxt'], '');
          expect((webPatient['occupants'] as List).first['dependenceTxt'], '');
          await repository.mergeRemoteDossierPayloads([web]);
          expect(
            (await repository.fetchAllDossiers()).single.patient.dependenceTxt,
            '',
          );
        }
      },
    );
  }
}
