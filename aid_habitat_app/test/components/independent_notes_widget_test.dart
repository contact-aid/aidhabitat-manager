import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aid_habitat_app/components/notes_widget.dart';
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
    'independent widgets preserve deliberate blanks on reopen despite a stale secondary page',
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
      const dossierKey = 'notes_rapides';
      const beneficiaryKey = 'Bénéficiaire-Notes';
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
        ]) {
          await notes.mergeRemoteNotePage(
            patientId: patient,
            dossierId: dossier,
            tabKey: key,
            pageNumber: page,
            drawingJson: jsonEncode({
              'version': 1,
              'text': text,
              'strokes': [],
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
      Future<void> open({int dossierPage = 0}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  for (final key in [dossierKey, beneficiaryKey])
                    Expanded(
                      child: NotesWidget(
                        key: ValueKey(key),
                        patientId: patient,
                        dossierId: dossier,
                        tabKey: key,
                        sharedText: key == dossierKey,
                        currentPage: key == dossierKey ? dossierPage : 0,
                        totalPages: key == dossierKey ? 2 : 1,
                        showCanvas: false,
                        showSaveButton: false,
                        fillParentHeight: true,
                        allowPagination: true,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
      }

      Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      );
      String shown(String key) =>
          tester.widget<TextField>(field(key)).controller!.text;
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
      expect(shown(dossierKey), '');
      expect(shown(beneficiaryKey), 'Texte iPad préservé');
      final openingWrites = await tester.runAsync(
        () async =>
            (await LocalDatabase.instance.database).query('sync_operations'),
      );
      expect(openingWrites, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(dossierPage: 1);
      expect(shown(dossierKey), '');
      expect(shown(beneficiaryKey), 'Texte iPad préservé');
      await tester.enterText(field(dossierKey), 'Modification dossier');
      await waitSaved(dossierKey, 'Modification dossier');
      expect(shown(beneficiaryKey), 'Texte iPad préservé');
      await tester.enterText(field(beneficiaryKey), '');
      await waitSaved(beneficiaryKey, '');
      expect(shown(dossierKey), 'Modification dossier');
      await tester.pumpWidget(const SizedBox.shrink());
      await open();
      expect(shown(dossierKey), 'Modification dossier');
      expect(shown(beneficiaryKey), '');
      expect(
        (await tester.runAsync(
          () => stored(beneficiaryKey),
        ))!['noteTextInitialized'],
        true,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previousPlatform;
    },
  );
}
