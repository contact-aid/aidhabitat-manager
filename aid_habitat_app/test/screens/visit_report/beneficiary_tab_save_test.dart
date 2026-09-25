import 'dart:async';
import 'dart:convert';

import 'package:aid_habitat_app/components/form_widgets.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/visit_report/beneficiary_tab.dart';
import 'package:aid_habitat_app/services/dossier_repository.dart';
import 'package:aid_habitat_app/services/save_debounce.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The storage maps can change independently of the loaded form, like a pull.
// Unexpected repository calls (including reads) fail through Fake.noSuchMethod.
class _Repository extends Fake implements DossierRepository {
  final patientWrites = <Map<String, dynamic>>[];
  final adminWrites = <Map<String, dynamic>>[];
  final patientStorage = <String, dynamic>{};
  final adminStorage = <String, dynamic>{};
  Future<void> Function()? onPatient;
  Future<void> Function()? onAdmin;
  int active = 0;
  int maxActive = 0;

  Future<void> _write(
    Map<String, dynamic> fields,
    List<Map<String, dynamic>> writes,
    Map<String, dynamic> storage,
    Future<void> Function()? beforeWrite,
  ) async {
    writes.add(Map.of(fields));
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await beforeWrite?.call();
      storage.addAll(fields);
    } finally {
      active--;
    }
  }

  @override
  Future<void> updatePatient(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) {
    expectSync(id, 'patient-1');
    return _write(fields, patientWrites, patientStorage, onPatient);
  }

  @override
  Future<void> updateDossierFields(
    String id,
    Map<String, dynamic> fields, {
    Map<String, dynamic>? observedFields,
  }) {
    expectSync(id, 'dossier-1');
    return _write(fields, adminWrites, adminStorage, onAdmin);
  }
}

Dossier _dossier({String phone = '0102030405', String email = 'old@test.fr'}) =>
    Dossier(
      id: 'dossier-1',
      patient: Patient(
        id: 'patient-1',
        firstName: 'Alice',
        lastName: 'Test',
        birthDate: '',
        phone: phone,
        email: email,
        address: 'Old address',
        city: 'Old city',
        zipCode: '75001',
        familySituation: '',
        incomeCategory: '',
        // Legacy values are normalized by the form but must not become edits.
        numberPeople: 0,
        fiscalRevenue: 12000,
        caisseRetraitePrincipale: 'Carsat; MSA',
        trustedPerson: TrustedPerson(name: 'Bob', phone: '', email: ''),
      ),
      status: DossierStatus.TO_VISIT,
      ergoId: 'ergo-1',
      housing: Housing(
        type: HousingType.HOUSE,
        heating: HeatingMode.ELECTRIC,
        accessibilityNotes: '',
      ),
      autonomyNotes: '',
      plans: {},
      createdAt: '2026-09-01',
      compteAnah: 'A faire',
      envoiRapport: 'Mail',
    );

Future<void> _mount(
  WidgetTester tester,
  _Repository repository, {
  Dossier? dossier,
  int section = 0,
  int conflictRefreshToken = 0,
  VoidCallback? onChanged,
  BeneficiaryTabController? controller,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BeneficiaryTab(
          dossier: dossier ?? _dossier(),
          repository: repository,
          controller: controller,
          initialSubSection: section,
          conflictRefreshToken: conflictRefreshToken,
          onPatientChanged: onChanged,
        ),
      ),
    ),
  );
  await tester.pump();
}

Finder _warningField(String label) => find.byWidgetPredicate(
  (widget) => widget is FormTextFieldWithWarning && widget.label == label,
);

Future<void> _edit(WidgetTester tester, String label, String value) async {
  await tester.enterText(
    find.descendant(of: _warningField(label), matching: find.byType(TextField)),
    value,
  );
  await tester.pump();
}

Future<void> _anah(WidgetTester tester, String value) async {
  tester
      .widget<FormToggleGroup>(
        find.byWidgetPredicate(
          (widget) =>
              widget is FormToggleGroup && widget.label.contains('compte ANAH'),
        ),
      )
      .onChanged!(value);
  await tester.pump();
}

Future<void> _flush(WidgetTester tester) async {
  await tester.pump(kSaveDebounceText);
  await tester.pump();
}

Future<void> _exhaustRetries(WidgetTester tester) async {
  for (final seconds in [1, 2, 4]) {
    await tester.pump(Duration(seconds: seconds));
    await tester.pump();
  }
}

void main() {
  testWidgets('generation flushes the latest beneficiary edit before debounce', (
    tester,
  ) async {
    final repository = _Repository();
    final controller = BeneficiaryTabController();
    await _mount(tester, repository, controller: controller);
    await _edit(tester, 'Téléphone', '');

    await tester.runAsync(controller.flushPendingSave);
    await tester.pump();

    expect(repository.patientWrites, [
      {'phone': ''},
    ]);
  });

  testWidgets('server choice refreshes dependence without saving stale form', (
    tester,
  ) async {
    final repository = _Repository();
    Patient patientWithDependence(String value) {
      final p = _dossier().patient;
      return Patient(
        id: p.id,
        firstName: p.firstName,
        lastName: p.lastName,
        birthDate: p.birthDate,
        phone: p.phone,
        email: p.email,
        address: p.address,
        city: p.city,
        zipCode: p.zipCode,
        familySituation: p.familySituation,
        incomeCategory: p.incomeCategory,
        trustedPerson: p.trustedPerson,
        dependenceTxt: value,
        occupants: [Occupant(dependenceTxt: value)],
      );
    }

    final local = _dossier().copyWith(patient: patientWithDependence('Canne'));
    await _mount(tester, repository, dossier: local, section: 2);
    FormToggleGroup dependence() => tester.widget<FormToggleGroup>(
      find.byWidgetPredicate(
        (widget) => widget is FormToggleGroup && widget.label == 'Dépendance',
      ),
    );
    expect(dependence().selected, 'Canne');

    final server = local.copyWith(patient: patientWithDependence('Aucune'));
    await _mount(
      tester,
      repository,
      dossier: server,
      section: 2,
      conflictRefreshToken: 1,
    );
    expect(dependence().selected, 'Aucune');
    await _flush(tester);
    expect(repository.patientWrites, isEmpty);
  });

  testWidgets('AGGIR notice follows the primary beneficiary age', (
    tester,
  ) async {
    final base = _dossier();
    final year = DateTime.now().year;
    const message =
        'Un GIR sera requis. Une grille AGGIR est disponible dans l’espace Documents.';
    for (final birthday in ['', '${year - 65}-01-01', '${year - 75}-01-01']) {
      await tester.pumpWidget(const SizedBox.shrink());
      await _mount(
        tester,
        _Repository(),
        dossier: base.copyWith(
          patient: base.patient.copyWith(birthDate: birthday),
        ),
      );
      expect(
        find.text(message),
        birthday == '${year - 65}-01-01' ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'only edited columns are sent despite independent storage changes',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository);
      await _edit(tester, 'Téléphone', '0602030405');
      repository.patientStorage.addAll({
        'address': 'Pulled address',
        'email': 'pulled@test.fr',
        'occupants_json': '[{"firstName":"Pulled"}]',
      });
      repository.adminStorage['envoi_rapport'] = 'Courrier';
      await _flush(tester);

      expect(repository.patientWrites, [
        {'phone': '0602030405'},
      ]);
      expect(repository.adminWrites, isEmpty);
      expect(repository.patientStorage['address'], 'Pulled address');
      expect(repository.patientStorage['email'], 'pulled@test.fr');
      expect(
        repository.patientStorage['occupants_json'],
        '[{"firstName":"Pulled"}]',
      );
      expect(repository.adminStorage['envoi_rapport'], 'Courrier');

      await _edit(tester, 'Email', 'local@test.fr');
      await _flush(tester);
      expect(repository.patientWrites.last, {'email': 'local@test.fr'});
      expect(repository.patientWrites, hasLength(2));
    },
  );

  testWidgets('admin-only edits skip the patient and other admin columns', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await _anah(tester, 'Déjà fait');
    await _flush(tester);
    expect(repository.patientWrites, isEmpty);
    expect(repository.adminWrites.single.keys, ['compte_anah']);
    expect(
      jsonDecode(repository.adminWrites.single['compte_anah'])['status'],
      'Déjà fait',
    );
  });

  testWidgets(
    'reverting before debounce is a no-op and does not lock later saves',
    (tester) async {
      final repository = _Repository();
      await _mount(tester, repository);
      await _edit(tester, 'Téléphone', '0602030405');
      await _edit(tester, 'Téléphone', '0102030405');
      await _flush(tester);
      expect(repository.patientWrites, isEmpty);
      expect(repository.adminWrites, isEmpty);
      await _edit(tester, 'Email', 'new@test.fr');
      await _flush(tester);
      expect(repository.patientWrites.single, {'email': 'new@test.fr'});
    },
  );

  testWidgets('serial saves preserve edits and a revert made during await', (
    tester,
  ) async {
    final repository = _Repository();
    final gate = Completer<void>();
    repository.onPatient = () => gate.future;
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    await _edit(tester, 'Téléphone', '0702030405');
    await _flush(tester);
    await _edit(tester, 'Téléphone', '0102030405');
    await _edit(tester, 'Email', 'latest@test.fr');
    await _flush(tester);

    // A parent refresh after debounce has expired must not rehydrate the form.
    await _mount(tester, repository, dossier: _dossier(phone: '0902030405'));
    expect(
      tester.widget<FormTextFieldWithWarning>(_warningField('Téléphone')).value,
      '0102030405',
    );
    expect(
      tester.widget<FormTextFieldWithWarning>(_warningField('Email')).value,
      'latest@test.fr',
    );
    expect(repository.patientWrites, hasLength(1));
    gate.complete();
    await tester.pump();
    expect(repository.patientWrites, [
      {'phone': '0602030405'},
      {'phone': '0102030405', 'email': 'latest@test.fr'},
    ]);
    expect(repository.maxActive, 1);
    expect(repository.adminWrites, isEmpty);
  });

  testWidgets(
    'both blocks are frozen before await and later admin edits drain',
    (tester) async {
      final repository = _Repository();
      final patientGate = Completer<void>();
      final adminGate = Completer<void>();
      repository.onPatient = () => patientGate.future;
      repository.onAdmin = () => adminGate.future;
      await _mount(tester, repository);
      await _edit(tester, 'Téléphone', '0602030405');
      await _anah(tester, 'Déjà fait');
      await _flush(tester);
      await _anah(tester, 'A vérifier');
      await _flush(tester);
      expect(repository.adminWrites, isEmpty);
      patientGate.complete();
      await tester.pump();
      expect(
        jsonDecode(repository.adminWrites.single['compte_anah'])['status'],
        'Déjà fait',
      );
      await _edit(tester, 'Email', 'latest@test.fr');
      await _flush(tester);
      expect(repository.patientWrites, hasLength(1));
      adminGate.complete();
      await tester.pump();
      expect(repository.patientWrites.last, {'email': 'latest@test.fr'});
      expect(repository.adminWrites, hasLength(2));
      expect(
        jsonDecode(repository.adminWrites.last['compte_anah'])['status'],
        'A vérifier',
      );
      expect(repository.maxActive, 1);
    },
  );

  testWidgets('failed edits survive refresh and retry with the next edit', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async => throw StateError('patient write failed');
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _anah(tester, 'Déjà fait');
    await _flush(tester);
    expect(tester.takeException(), isNull);
    expect(repository.adminWrites, isEmpty);
    await tester.pump(const Duration(milliseconds: 500));
    expect(repository.patientWrites, hasLength(1));
    await _mount(tester, repository, dossier: _dossier(phone: '0902030405'));
    expect(
      tester.widget<FormTextFieldWithWarning>(_warningField('Téléphone')).value,
      '0602030405',
    );
    repository.onPatient = null;
    await _edit(tester, 'Email', 'retry@test.fr');
    await _flush(tester);
    expect(repository.patientWrites.last, {
      'phone': '0602030405',
      'email': 'retry@test.fr',
    });
    expect(repository.adminWrites.single.keys, ['compte_anah']);
  });

  testWidgets('partial success advances only the confirmed block on retry', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onAdmin = () async => throw StateError('admin write failed');
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _anah(tester, 'Déjà fait');
    await _flush(tester);
    expect(repository.patientWrites, hasLength(1));
    expect(repository.adminWrites, hasLength(1));
    expect(tester.takeException(), isNull);
    repository.onAdmin = null;
    await _anah(tester, 'A vérifier');
    await _flush(tester);
    expect(repository.patientWrites, hasLength(1));
    expect(repository.adminWrites, hasLength(2));
    expect(
      jsonDecode(repository.adminWrites.last['compte_anah'])['status'],
      'A vérifier',
    );
  });

  testWidgets('a clean parent reload resets the form comparison snapshot', (
    tester,
  ) async {
    final repository = _Repository();
    await _mount(tester, repository);
    await _mount(tester, repository, dossier: _dossier(phone: '0902030405'));
    await _edit(tester, 'Email', 'new@test.fr');
    await _flush(tester);
    expect(repository.patientWrites.single, {'email': 'new@test.fr'});
    await _edit(tester, 'Téléphone', '0102030405');
    await _flush(tester);
    expect(repository.patientWrites.last, {'phone': '0102030405'});
  });

  testWidgets('dispose flushes debounce without notifying the removed parent', (
    tester,
  ) async {
    final repository = _Repository();
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(repository.patientWrites.single, {'phone': '0602030405'});
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose during save drains the latest edits without overlap', (
    tester,
  ) async {
    final repository = _Repository();
    final gate = Completer<void>();
    repository.onPatient = () => gate.future;
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    await _edit(tester, 'Téléphone', '0702030405');
    await _anah(tester, 'Déjà fait');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(repository.patientWrites, hasLength(1));
    gate.complete();
    await tester.pump();
    expect(repository.patientWrites.last, {'phone': '0702030405'});
    expect(repository.patientWrites, hasLength(2));
    expect(repository.adminWrites.single.keys, ['compte_anah']);
    expect(repository.maxActive, 1);
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose retries unconfirmed edits after an earlier failure', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onAdmin = () async => throw StateError('admin write failed');
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _anah(tester, 'Déjà fait');
    await _flush(tester);
    repository.onAdmin = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(repository.patientWrites, hasLength(1));
    expect(repository.adminWrites, hasLength(2));
    expect(repository.adminWrites.first, repository.adminWrites.last);
    expect(tester.takeException(), isNull);
  });

  testWidgets('transient failure retries automatically after the backoff', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async {
      if (repository.patientWrites.length == 1) throw StateError('temporary');
    };
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    expect(repository.patientWrites, hasLength(1));
    expect(notifications, 0);
    await tester.pump(const Duration(milliseconds: 999));
    expect(repository.patientWrites, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(repository.patientWrites, [
      {'phone': '0602030405'},
      {'phone': '0602030405'},
    ]);
    expect(repository.patientStorage['phone'], '0602030405');
    expect(notifications, 1);
    expect(find.byType(MaterialBanner), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('permanent failure stops after three retries and offers retry', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async => throw StateError('permanent');
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    for (final seconds in [1, 2, 4]) {
      final before = repository.patientWrites.length;
      await tester.pump(Duration(milliseconds: seconds * 1000 - 1));
      expect(repository.patientWrites, hasLength(before));
      expect(find.byType(MaterialBanner), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(repository.patientWrites, hasLength(before + 1));
    }
    expect(repository.patientWrites, hasLength(4));
    expect(find.byType(BeneficiaryTab), findsOneWidget);
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
    expect(
      tester.widget<FormTextFieldWithWarning>(_warningField('Téléphone')).value,
      '0602030405',
    );
    expect(notifications, 0);
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(4));

    // The error remains readable on a phone, without closing the tab.
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final gate = Completer<void>();
    repository.onPatient = () => gate.future;
    await tester.tap(find.text('Réessayer'));
    // A second tap before the next frame must reuse the in-flight save.
    await tester.tap(find.text('Réessayer'));
    await tester.pump();
    expect(repository.patientWrites, hasLength(5));
    expect(repository.maxActive, 1);
    gate.complete();
    await tester.pump();
    expect(find.byType(MaterialBanner), findsNothing);
    expect(notifications, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new edit resets the exhausted retry budget once', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async => throw StateError('permanent');
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    await _exhaustRetries(tester);
    expect(repository.patientWrites, hasLength(4));
    await _edit(tester, 'Email', 'latest@test.fr');
    expect(find.byType(MaterialBanner), findsNothing);
    await _flush(tester);
    expect(repository.patientWrites, hasLength(5));
    await _exhaustRetries(tester);
    expect(repository.patientWrites, hasLength(8));
    expect(repository.patientWrites.last, {
      'phone': '0602030405',
      'email': 'latest@test.fr',
    });
    expect(find.byType(MaterialBanner), findsOneWidget);
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(8));
    // Disposal still makes a single best-effort flush, never an auto-retry loop.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(9));
    expect(tester.takeException(), isNull);
  });

  testWidgets('edits replace backoff and failure cancels a pending debounce', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async => throw StateError('temporary');
    await _mount(tester, repository);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    await tester.pump(const Duration(milliseconds: 500));
    final gate = Completer<void>();
    repository.onPatient = () => gate.future;
    await _edit(tester, 'Email', 'latest@test.fr');
    await _flush(tester);
    expect(repository.patientWrites, hasLength(2));
    // The old retry deadline expires while the new save is in flight.
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.patientWrites, hasLength(2));
    await _edit(tester, 'Téléphone', '0702030405');
    gate.completeError(StateError('temporary'));
    await tester.pump();
    repository.onPatient = null;
    await _flush(tester);
    expect(repository.patientWrites, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(repository.patientWrites, hasLength(3));
    expect(repository.patientWrites.last, {
      'phone': '0702030405',
      'email': 'latest@test.fr',
    });
    expect(repository.maxActive, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dispose cancels backoff and a failing flush creates no timer', (
    tester,
  ) async {
    final repository = _Repository();
    repository.onPatient = () async => throw StateError('permanent');
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    expect(repository.patientWrites, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(repository.patientWrites, hasLength(2));
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(2));
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a retry failing after dispose neither notifies nor retries', (
    tester,
  ) async {
    final repository = _Repository();
    final gate = Completer<void>();
    repository.onPatient = () {
      if (repository.patientWrites.length == 1) throw StateError('temporary');
      return gate.future;
    };
    var notifications = 0;
    await _mount(tester, repository, onChanged: () => notifications++);
    await _edit(tester, 'Téléphone', '0602030405');
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(repository.patientWrites, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    gate.completeError(StateError('permanent'));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(repository.patientWrites, hasLength(2));
    expect(repository.maxActive, 1);
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });
}
