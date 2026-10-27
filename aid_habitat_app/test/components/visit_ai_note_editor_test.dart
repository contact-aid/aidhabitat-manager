import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:aid_habitat_app/services/note_repository.dart';

void main() {
  sqfliteFfiInit();
  testWidgets(
    'an open focused editor preserves typing, receives an append and keeps later human corrections',
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousApi = AppConfig.apiBaseUrl;
      late Directory directory;
      final notes = NoteRepository();
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('visit-ai-editor-');
        databaseFactory = databaseFactoryFfi;
        await databaseFactoryFfi.setDatabasesPath(directory.path);
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        AppConfig.setApiBaseUrl('');
        await notes.saveDrawingJson(
          patientId: 'fictional-patient',
          dossierId: 'fictional-dossier',
          tabKey: 'Accessibilité-Notes',
          drawingJson: '{"version":1,"text":"Note existante","strokes":[]}',
          mutationOrigin: SyncMutationOrigin.userEdit,
        );
      });
      addTearDown(() async {
        await (await LocalDatabase.instance.database).close();
        await directory.delete(recursive: true);
        debugDefaultTargetPlatformOverride = previousPlatform;
        AppConfig.setApiBaseUrl(previousApi);
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 500,
              child: NotesWidget(
                patientId: 'fictional-patient',
                dossierId: 'fictional-dossier',
                tabKey: 'Accessibilité-Notes',
                showCanvas: false,
                showSaveButton: false,
                allowPagination: false,
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pump();
      final editor = find.byType(EditableText).first;
      await tester.enterText(editor, 'Note existante et frappe en cours');
      await tester.runAsync(() async {
        await notes.appendVisitText(
          patientId: 'fictional-patient',
          dossierId: 'fictional-dossier',
          tabKey: 'Accessibilité-Notes',
          recordingId: 'visit-1',
          text: 'Texte généré',
        );
      });
      await tester.pump();
      expect(
        tester.widget<EditableText>(editor).controller.text,
        'Note existante et frappe en cours\n\nTexte généré',
      );
      await tester.enterText(editor, 'Texte relu librement par l’ergo');
      Map<String, dynamic>? observed;
      var reading = false;
      for (var i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(() async {
          if (!reading) {
            reading = true;
            notes
                .fetchDrawingJson(
                  patientId: 'fictional-patient',
                  dossierId: 'fictional-dossier',
                  tabKey: 'Accessibilité-Notes',
                )
                .then((raw) {
                  observed = jsonDecode(raw!) as Map<String, dynamic>;
                  reading = false;
                });
          }
          await Future<void>.delayed(const Duration(milliseconds: 15));
        });
        if (observed?['text'] == 'Texte relu librement par l’ergo') break;
      }
      expect(observed?['text'], 'Texte relu librement par l’ergo');
      await tester.runAsync(() async {
        await notes.appendVisitText(
          patientId: 'fictional-patient',
          dossierId: 'fictional-dossier',
          tabKey: 'Accessibilité-Notes',
          recordingId: 'visit-1',
          text: 'Texte généré',
        );
        final saved =
            jsonDecode(
                  (await notes.fetchDrawingJson(
                    patientId: 'fictional-patient',
                    dossierId: 'fictional-dossier',
                    tabKey: 'Accessibilité-Notes',
                  ))!,
                )
                as Map;
        expect(saved['text'], 'Texte relu librement par l’ergo');
      });
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = previousPlatform;
    },
  );
}
