import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/screens/visit_report/sanitary_notes_panel.dart';
import 'package:aid_habitat_app/services/sanitary_notes.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  testWidgets(
    'sanitary observation stays shared while each manuscript paginates independently',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousApi = AppConfig.apiBaseUrl;
      final previousSession = AppConfig.appSessionToken;
      late Directory directory;
      late NoteRepository notes;
      const patient = 'patient-independent-fiction';
      const dossier = 'dossier-independent-fiction';
      const dossierKey = sanitaryTextTabKey;
      const beneficiaryKey = bathroomDrawingTabKey;
      const accessibilityKey = wcDrawingTabKey;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('independent-notes-');
        databaseFactory = databaseFactoryFfi;
        await databaseFactoryFfi.setDatabasesPath(directory.path);
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        AppConfig.setApiBaseUrl('');
        AppConfig.clearAppSessionToken();
        notes = NoteRepository();
        for (final (key, page, text, initialized) in [
          (dossierKey, 0, '', true),
          (dossierKey, 1, 'Ancien texte à ne pas ressusciter', false),
          (beneficiaryKey, 0, 'Texte iPad préservé', true),
          (accessibilityKey, 0, 'Observation commune', false),
          (accessibilityKey, 1, 'Ancienne observation secondaire', false),
        ]) {
          await notes.mergeRemoteNotePage(
            patientId: patient,
            dossierId: dossier,
            tabKey: key,
            pageNumber: page,
            drawingJson: jsonEncode({
              'version': 1,
              'text': text,
              'strokes': key == accessibilityKey
                  ? [
                      {
                        'tool': 'pen',
                        'color': '#000000',
                        'size': 2,
                        'points': [
                          {'x': 0.1 + page * 0.2, 'y': 0.2},
                        ],
                      },
                    ]
                  : [],
              if (initialized) 'noteTextInitialized': true,
            }),
            revision: '00000000-0000-4000-8000-000000000001',
          );
        }
      });
      addTearDown(() async {
        await (await LocalDatabase.instance.database).close();
        await directory.delete(recursive: true);
        debugDefaultTargetPlatformOverride = previousPlatform;
        AppConfig.setApiBaseUrl(previousApi);
        AppConfig.setAppSessionToken(previousSession);
      });
      String? liveText;
      Future<void> open() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => Row(
                  children: [
                    for (final isBathroom in [true, false])
                      Expanded(
                        child: SanitaryNotesPanel(
                          key: ValueKey(isBathroom),
                          patientId: patient,
                          isBathroom: isBathroom,
                          liveText: liveText,
                          onTextDraft: (draft) {
                            if (liveText != draft.text) {
                              setState(() => liveText = draft.text);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
      }

      Future<Map<String, dynamic>> stored(String key) async =>
          jsonDecode(
                (await notes.fetchDrawingJson(
                  patientId: patient,
                  tabKey: key,
                ))!,
              )
              as Map<String, dynamic>;
      Future<void> waitSaved(String key, String text) async {
        await tester.pump(const Duration(seconds: 2));
        Map<String, dynamic>? snapshot;
        Object? readError;
        bool reading = false;
        for (var i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          // Never await a competing SQLite read while a debounce transaction
          // is still resuming in the widget test's fake async zone.
          await tester.runAsync(() async {
            if (!reading) {
              reading = true;
              unawaited(
                stored(key).then(
                  (value) {
                    snapshot = value;
                    reading = false;
                  },
                  onError: (Object error) {
                    readError = error;
                    reading = false;
                  },
                ),
              );
            }
            await Future<void>.delayed(const Duration(milliseconds: 15));
          });
          if (readError != null) throw readError!;
          if (snapshot?['text'] == text) return;
        }
        fail('Text not saved: $key');
      }

      await open();
      final keyboardFields = find.descendant(
        of: find.byType(SanitaryNotesPanel),
        matching: find.byType(TextField),
      );
      expect(keyboardFields, findsNWidgets(2));
      await tester.enterText(
        keyboardFields.first,
        'Observation commune corrigée',
      );
      await tester.pump();
      expect(
        tester.widget<TextField>(keyboardFields.last).controller!.text,
        'Observation commune corrigée',
      );
      await waitSaved(dossierKey, 'Observation commune corrigée');
      final textWidgets = tester
          .widgetList<NotesWidget>(find.byType(NotesWidget))
          .where((w) => w.tabKey == sanitaryTextTabKey);
      expect(
        textWidgets.every(
          (w) => w.maxPages == 1 && !w.allowPagination && !w.showCanvas,
        ),
        true,
      );
      final wc = find.byKey(ValueKey('$patient::$wcDrawingTabKey'));
      final bathroom = find.byKey(ValueKey('$patient::$bathroomDrawingTabKey'));
      final beforeText = await tester.runAsync(() => stored(dossierKey));
      await tester.tap(
        find.descendant(of: wc, matching: find.byTooltip('Nouvelle page')),
      );
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)),
        );
      }
      expect(
        find.descendant(of: wc, matching: find.text('3/3')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bathroom, matching: find.text('1/2')),
        findsOneWidget,
      );
      expect(await tester.runAsync(() => stored(dossierKey)), beforeText);
      await tester.enterText(keyboardFields.last, '');
      await waitSaved(dossierKey, '');
      expect(
        tester.widget<TextField>(keyboardFields.first).controller!.text,
        '',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      liveText = null;
      await open();
      expect(
        tester
            .widgetList<TextField>(keyboardFields)
            .every((f) => f.controller!.text.isEmpty),
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previousPlatform;
    },
  );
}
