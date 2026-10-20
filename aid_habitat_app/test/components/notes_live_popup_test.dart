import 'dart:io';

import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:aid_habitat_app/screens/note_window_screen.dart';
import 'package:aid_habitat_app/services/app_config.dart';
import 'package:aid_habitat_app/services/local_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  testWidgets(
    'focused notes mirror popup text and clicks never send stale drafts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousApi = AppConfig.apiBaseUrl;
      final previousSession = AppConfig.appSessionToken;
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('notes-live-popup-');
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
      const patient = 'fiction-live-popup';
      const tab = 'Contexte de vie-Autonomie';
      final drafts = <String>[];
      Widget screen({String? liveText}) => MaterialApp(
        home: Scaffold(
          body: NotesWidget(
            patientId: patient,
            tabKey: tab,
            title: 'Habitudes de vie',
            showCanvas: false,
            sharedText: true,
            liveText: liveText,
            autoSaveToService: false,
            onDraftChange: (draft) => drafts.add(draft.text),
          ),
        ),
      );
      Future<void> settleStorage() async {
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 30));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)),
          );
        }
      }

      await tester.pumpWidget(screen());
      await settleStorage();
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);

      await tester.pumpWidget(screen(liveText: 'Texte saisi dans la fenêtre'));
      await tester.pump();
      expect(controller.text, 'Texte saisi dans la fenêtre');
      controller.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();
      expect(
        drafts,
        isEmpty,
        reason: 'a selection change must not publish a draft',
      );
      expect(controller.text, 'Texte saisi dans la fenêtre');

      await tester.enterText(field, 'Texte complété dans les notes');
      expect(drafts, ['Texte complété dans les notes']);
      await tester.pumpWidget(
        screen(liveText: 'Texte complété dans la fenêtre aussi'),
      );
      await tester.pump();
      expect(controller.text, 'Texte complété dans la fenêtre aussi');
      expect(drafts, hasLength(1), reason: 'incoming text must not echo');

      // A deliberate empty incoming draft is an edit too.
      await tester.pumpWidget(screen(liveText: ''));
      await tester.pump();
      expect(controller.text, isEmpty);
      controller.selection = const TextSelection.collapsed(offset: 0);
      expect(drafts, hasLength(1));

      // The floating in-app editor shares the same controller in both directions.
      await tester.tap(find.byIcon(LucideIcons.maximize2).first);
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields, hasLength(2));
      expect(identical(fields[0].controller, fields[1].controller), isTrue);
      await tester.enterText(
        find.byType(TextField).last,
        'Brouillon de la fenêtre flottante',
      );
      expect(controller.text, 'Brouillon de la fenêtre flottante');
      controller.text = 'Modification côté notes';
      await tester.pump();
      expect(fields.last.controller!.text, 'Modification côté notes');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = previousPlatform;
    },
  );

  testWidgets('detached editor accepts pushNote while focused without echo', (
    tester,
  ) async {
    const channel = MethodChannel('mixin.one/flutter_multi_window_channel');
    final sent = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      sent.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: NoteWindowScreen(
          windowId: 1,
          patientId: 'fiction',
          tabKey: 'Contexte de vie-Autonomie',
          title: 'Habitudes de vie',
          initialText: 'Ancien texte',
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    sent.clear();
    final codec = const StandardMethodCodec();
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        const MethodCall('pushNote', {
          'fromWindowId': 0,
          'arguments': {
            'patientId': 'fiction',
            'tabKey': 'Contexte de vie-Autonomie',
            'text': 'Texte des notes synchronisé',
          },
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Texte des notes synchronisé',
    );
    expect(sent.where((call) => call.method == 'liveNote'), isEmpty);
    await tester.enterText(field, 'Suite saisie dans la fenêtre');
    expect(sent.where((call) => call.method == 'liveNote'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
