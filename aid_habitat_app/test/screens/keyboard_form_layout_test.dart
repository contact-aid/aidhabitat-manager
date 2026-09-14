import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/screens/login_screen.dart';
import 'package:aid_habitat_app/screens/wiki_screen.dart';
import 'package:aid_habitat_app/services/auth_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

class _Auth extends Fake implements AuthService {
  @override
  Future<List<LocalAppUser>> fetchAvailableUsers() async => [];
}

void main() {
  setUp(() => GoogleFonts.config.allowRuntimeFetching = false);
  for (final size in [const Size(1180, 820), const Size(820, 1180)]) {
    testWidgets('library editing remains scrollable with keyboard $size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: buildWikiItemDialogForTesting(
              const WikiItem(
                id: 'test',
                title: 'Test',
                description: 'Description',
                imageUrl: '',
                tags: ['Autre'],
                category: 'Autre',
                createdAt: '',
                updatedAt: '',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Changed title');
      tester.view.viewInsets = FakeViewPadding(bottom: size.height * .48);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.text('Enregistrer')).bottom,
        lessThanOrEqualTo(size.height * .52),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Changed title',
      );
      expect(tester.takeException(), isNull);
    });
    for (final scale in [1.0, 1.5]) {
      testWidgets('login contains form with keyboard $size scale $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: LoginScreen(authService: _Auth(), onLoggedIn: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'draft-password');
        tester.view.viewInsets = FakeViewPadding(bottom: size.height * .48);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byType(FilledButton));
        await tester.pumpAndSettle();
        final button = tester.getRect(find.byType(FilledButton));
        expect(button.bottom, lessThanOrEqualTo(size.height * .52 + 1));
        final container = find
            .ancestor(
              of: find.byType(FilledButton),
              matching: find.byType(Container),
            )
            .last;
        expect(tester.getRect(container).contains(button.bottomCenter), isTrue);
        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'draft-password',
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'library scrolls fields and actions above keyboard $size scale $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(body: buildWikiCreateDialogForTesting()),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).first, 'Test item');
          tester.view.viewInsets = FakeViewPadding(bottom: size.height * .48);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text('Créer'));
          await tester.pumpAndSettle();
          final button = tester.getRect(
            find.widgetWithText(FilledButton, 'Créer'),
          );
          expect(button.bottom, lessThanOrEqualTo(size.height * .52 + 1));
          expect(
            tester.getRect(find.byType(Dialog)).contains(button.bottomCenter),
            isTrue,
          );
          tester.view.viewInsets = FakeViewPadding.zero;
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(find.byType(TextField).first)
                .controller!
                .text,
            'Test item',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
