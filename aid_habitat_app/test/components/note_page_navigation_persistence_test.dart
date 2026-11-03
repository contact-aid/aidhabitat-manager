import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
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
  testWidgets('Pencil draft survives immediate page navigation and closing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final previousPlatform = debugDefaultTargetPlatformOverride;
    final previousApi = AppConfig.apiBaseUrl;
    final previousSession = AppConfig.appSessionToken;
    late Directory directory;
    final notes = NoteRepository();
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('note-navigation-');
      databaseFactory = databaseFactoryFfi;
      await databaseFactoryFfi.setDatabasesPath(directory.path);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      AppConfig.setApiBaseUrl('');
      AppConfig.clearAppSessionToken();
    });
    addTearDown(() async {
      await (await LocalDatabase.instance.database).close();
      await directory.delete(recursive: true);
      debugDefaultTargetPlatformOverride = previousPlatform;
      AppConfig.setApiBaseUrl(previousApi);
      AppConfig.setAppSessionToken(previousSession);
    });
    final savedStrokes = <String, int>{};
    for (final (tab, closeImmediately) in [
      ('Sanitaires-Notes', false),
      ('Sanitaires-WC-Manuscrit', false),
      ('Sanitaires-Notes', true),
      ('Sanitaires-WC-Manuscrit', true),
    ]) {
      final patient = 'fiction-$tab-$closeImmediately';
      await tester.runAsync(() async {
        for (var page = 0; page < 4; page++) {
          await notes.mergeRemoteNotePage(
            patientId: patient,
            tabKey: tab,
            pageNumber: page,
            drawingJson: jsonEncode({
              'version': 1,
              'text': '',
              'strokes': page == 1
                  ? []
                  : [
                      {
                        'tool': 'pen',
                        'color': '#2563eb',
                        'size': 2,
                        'points': [
                          {'x': 0.1 + page * 0.1, 'y': 0.3},
                        ],
                      },
                    ],
            }),
            revision: '00000000-0000-4000-8000-000000000001',
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NotesWidget(
              key: ValueKey(tab),
              patientId: patient,
              tabKey: tab,
              totalPages: 4,
              currentPage: 1,
              sharedText: tab == 'Sanitaires-Notes',
              showText: false,
              showSaveButton: false,
              fillParentHeight: true,
              stackedCards: true,
            ),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      final canvas = find.byWidgetPredicate(
        (w) =>
            w is Listener &&
            w.onPointerDown != null &&
            w.onPointerMove != null &&
            w.onPointerUp != null,
      );
      expect(canvas, findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getRect(canvas).center,
        kind: PointerDeviceKind.stylus,
      );
      await gesture.moveBy(const Offset(60, 30));
      await gesture.up();
      // Navigate and close before the 300 ms drawing debounce expires.
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'Page suivante',
        ),
      );
      for (var i = 0; i < (closeImmediately ? 0 : 25); i++) {
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      if (!closeImmediately) expect(find.text('3/4'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      final json = await tester.runAsync(
        () => notes.fetchDrawingJson(
          patientId: patient,
          tabKey: tab,
          pageNumber: 1,
        ),
      );
      for (final neighbor in [0, 2, 3]) {
        final neighborJson = await tester.runAsync(
          () => notes.fetchDrawingJson(
            patientId: patient,
            tabKey: tab,
            pageNumber: neighbor,
          ),
        );
        expect(
          (jsonDecode(neighborJson!)['strokes'] as List).length,
          1,
          reason: 'Neighbor page ${neighbor + 1} must remain intact',
        );
      }
      savedStrokes['$tab:$closeImmediately'] =
          (jsonDecode(json!)['strokes'] as List).length;
    }
    debugDefaultTargetPlatformOverride = previousPlatform;
    expect(savedStrokes, {
      'Sanitaires-Notes:false': 1,
      'Sanitaires-WC-Manuscrit:false': 1,
      'Sanitaires-Notes:true': 1,
      'Sanitaires-WC-Manuscrit:true': 1,
    });
  });
}
