import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/components/feedback_tab.dart';
import 'package:aid_habitat_app/components/cta_text_style.dart';
import 'package:aid_habitat_app/components/beneficiary_header.dart';
import 'package:aid_habitat_app/services/feedback_activity_service.dart';
import 'package:aid_habitat_app/services/auth_service.dart';
import 'package:aid_habitat_app/screens/dashboard_screen.dart';
import 'package:aid_habitat_app/screens/dossier_screen.dart';
import 'package:aid_habitat_app/screens/visit_report_screen.dart';
import 'package:aid_habitat_app/screens/dossiers_list_screen.dart';
import 'package:aid_habitat_app/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:google_fonts/google_fonts.dart';

class _LayoutAuthService implements AuthService {
  @override
  Future<List<LocalAppUser>> fetchAvailableUsers() async => const [
    LocalAppUser(
      id: 'layout-user',
      email: 'layout@example.invalid',
      displayName: 'Camille Martin',
      role: LocalUserRole.ergo,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('CTA uses the former Signaler font variant at 14 px', (
    tester,
  ) async {
    TextStyle? inheritedStyle;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          textTheme: GoogleFonts.quicksandTextTheme(
            ThemeData.light().textTheme,
          ),
        ),
        home: Material(
          child: Builder(
            builder: (context) {
              inheritedStyle = DefaultTextStyle.of(context).style;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    expect(kCtaTextStyle.fontFamily, inheritedStyle!.fontFamily);
    expect(
      kCtaTextStyle.fontFamilyFallback,
      inheritedStyle!.fontFamilyFallback,
    );
    expect(kCtaTextStyle.fontSize, 14);
    expect(kCtaTextStyle.fontWeight, FontWeight.w800);
  });

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await initializeDateFormatting('fr_FR');
  });

  Dossier sampleDossier() => Dossier(
    id: 'layout-test',
    patient: Patient(
      id: 'patient-layout-test',
      firstName: 'Camille',
      lastName: 'Martin',
      birthDate: '1950-01-01',
      phone: '0102030405',
      email: '',
      address: '',
      city: '',
      zipCode: '',
      familySituation: '',
      incomeCategory: '',
      trustedPerson: TrustedPerson(name: '', phone: '', email: ''),
    ),
    status: DossierStatus.TO_VISIT,
    ergoId: 'ergo-layout-test',
    visitDate: DateTime.now().add(const Duration(days: 1)).toIso8601String(),
    housing: Housing(
      type: HousingType.APARTMENT,
      heating: HeatingMode.ELECTRIC,
      accessibilityNotes: '',
    ),
    autonomyNotes: '',
    plans: {},
    createdAt: DateTime.now().toIso8601String(),
  );

  for (final width in [320.0, 1280.0]) {
    testWidgets('login fits at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(
            onLoggedIn: (_) {},
            authService: _LayoutAuthService(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connexion'), findsOneWidget);
      expect(find.text("Ouvrir l'application"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('dashboard and dossiers fit at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(
              visits: const [],
              dossiers: const [],
              pendingSyncCount: 0,
              isSyncing: false,
              onSyncNow: () {},
              onSelectDossier: (_) {},
              onNavigateToDossiers: () {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DossiersListScreen(
              dossiers: const [],
              onSelectDossier: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('next visit action fits at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DashboardScreen(
              visits: const [],
              dossiers: [sampleDossier()],
              pendingSyncCount: 0,
              isSyncing: false,
              onSyncNow: () {},
              onSelectDossier: (_) {},
              onNavigateToDossiers: () {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Démarrer le relevé'), findsOneWidget);
      final startButton = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Démarrer le relevé'),
          matching: find.byWidgetPredicate((widget) => widget is ElevatedButton),
        ),
      );
      final startShape = startButton.style!.shape!.resolve({}) as RoundedRectangleBorder;
      expect(startShape.borderRadius, BorderRadius.circular(999));
    });

    testWidgets('populated dossiers fit at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DossiersListScreen(
              dossiers: [sampleDossier()],
              onSelectDossier: (_) {},
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('manual dossier refresh obeys connectivity at $width px', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var refreshCount = 0;

      Widget screen({required bool online, bool refreshing = false}) =>
          MaterialApp(
            home: Scaffold(
              body: DossiersListScreen(
                dossiers: const [],
                onSelectDossier: (_) {},
                isOnline: online,
                isRefreshingDossiers: refreshing,
                onRefreshDossiers: () async => refreshCount++,
              ),
            ),
          );
      final refreshButton = find.byWidgetPredicate((widget) => widget is ElevatedButton);

      await tester.pumpWidget(screen(online: false));
      expect(
        tester.widget<ElevatedButton>(refreshButton).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(screen(online: true));
      final refresh = tester.getTopLeft(refreshButton);
      final refreshShape = tester.widget<ElevatedButton>(refreshButton)
          .style!.shape!.resolve({}) as RoundedRectangleBorder;
      expect(refreshShape.borderRadius, BorderRadius.circular(999));
      final title = tester.getTopLeft(find.text('Mes dossiers'));
      expect(refresh.dx, greaterThan(title.dx));
      await tester.tap(find.text('Actualiser'));
      await tester.pump();
      expect(refreshCount, 1);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(screen(online: true, refreshing: true));
      expect(
        tester.widget<ElevatedButton>(refreshButton).onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Signaler panel fits at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: FeedbackTab(
                currentUser: const LocalAppUser(
                  id: 'layout-test',
                  email: 'test@example.invalid',
                  displayName: 'Test',
                  role: LocalUserRole.ergo,
                ),
                contextSnapshot: () => const FeedbackContextSnapshot(
                  page: 'test',
                  dossierId: '',
                  dossierName: '',
                  section: '',
                  lastAction: '',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('collapsed')),
          matching: find.text('Signaler'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('beneficiary header fits at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BeneficiaryHeader(dossier: sampleDossier(), onBack: () {}),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('dossier detail preview at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: DossierScreen(dossier: sampleDossier(), onBack: () {}),
        ),
      );
      expect(tester.takeException(), isNull);
    });
    testWidgets('visit report preview at $width px', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 800);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: VisitReportScreen(dossier: sampleDossier(), onBack: () {}),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  test('only admins can see all locally cached dossiers', () {
    final own = sampleDossier();
    final other = sampleDossier().copyWith(ergoId: 'another-ergo');
    final dossiers = [own, other];
    const admin = LocalAppUser(
      id: 'admin',
      email: 'admin@example.invalid',
      displayName: 'Admin',
      role: LocalUserRole.admin,
    );
    const ergo = LocalAppUser(
      id: 'ergo',
      email: 'ergo@example.invalid',
      displayName: 'Ergo',
      role: LocalUserRole.ergo,
      ergoLabel: 'ergo-layout-test',
      scopes: [LocalAccessScope(type: 'dossier_access', value: '*')],
    );
    expect(AuthService().filterDossiersForUser(dossiers, admin), hasLength(2));
    expect(AuthService().filterDossiersForUser(dossiers, ergo), [own]);
  });
}
