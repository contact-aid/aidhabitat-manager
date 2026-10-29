import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/components/visit_transcript_workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('Preview');
    font.addFont(
      Future.value(
        ByteData.sublistView(
          await File('assets/documents/Inter-Medium.ttf').readAsBytes(),
        ),
      ),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final emojiFile = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (await emojiFile.exists()) {
      final emoji = FontLoader('Apple Color Emoji')
        ..addFont(
          Future.value(ByteData.sublistView(await emojiFile.readAsBytes())),
        );
      await emoji.load();
    }
  });
  final transcript = List.generate(
    24,
    (i) => <String, dynamic>{
      'index': i,
      'startSeconds': i * 60,
      'text': i == 20
          ? 'Le seuil de la douche mesure 12 cm. La porte mesure 78 cm.'
          : 'Avez-vous rencontré des difficultés pour circuler dans votre logement ?\nJe marche avec une canne et je souhaite rester chez moi.',
      'turns': i == 20
          ? [
              {
                'text':
                    'Le seuil de la douche mesure 12 cm. La porte mesure 78 cm.',
                'role': 'other',
                'voice': 'man',
              },
            ]
          : [
              {
                'text':
                    'Avez-vous rencontré des difficultés pour circuler dans votre logement ?',
                'role': 'therapist',
                'voice': 'woman',
              },
              {
                'text':
                    'Je marche avec une canne et je souhaite rester chez moi.',
                'role': 'other',
                'voice': 'man',
              },
            ],
    },
  );
  Future<void> mount(
    WidgetTester tester, {
    double width = 1200,
    Future<Map<String, dynamic>> Function(String)? ask,
    List<Map<String, dynamic>>? data,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 780);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'Preview',
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF8D709F)),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: RepaintBoundary(
              key: const ValueKey('preview'),
              child: VisitTranscriptWorkspace(
                transcript: data ?? transcript,
                onAsk:
                    ask ??
                    (_) async => {
                      'answer': 'Le seuil de la douche mesure 12 cm.',
                      'sources': [20],
                      'citations': [
                        {
                          'index': 20,
                          'quote': 'Le seuil de la douche mesure 12 cm.',
                        },
                      ],
                    },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'answer scrolls the independent transcript to its exact cited passage; chips revisit it',
    (tester) async {
      await mount(tester);
      expect(
        tester.getTopLeft(find.text('Transcription')).dx,
        lessThan(tester.getTopLeft(find.text('Questions sur la visite')).dx),
      );
      await tester.enterText(
        find.byKey(const ValueKey('visit-question')),
        'Quelle est la hauteur du seuil de douche ?',
      );
      await tester.tap(find.byTooltip('Envoyer la question'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('transcript-scroll')),
          )
          .controller!;
      expect(scroll.offset, greaterThan(1000));
      final highlighted = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .where(
            (t) =>
                t.textSpan?.toPlainText().contains('La porte mesure 78') ==
                true,
          )
          .single;
      final spans = highlighted.textSpan!.children!.cast<TextSpan>();
      expect(
        spans.where((s) => s.style?.backgroundColor != null).single.text,
        'Le seuil de la douche mesure 12 cm.',
      );
      expect(spans.last.text, ' La porte mesure 78 cm.');
      expect(find.text('Voix non identifiée'), findsNothing);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.tap(find.text('20:00').last);
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(1000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unanswered question leaves transcript in place and clears old highlights',
    (tester) async {
      await mount(
        tester,
        ask: (_) async => {
          'answer': 'Cette information n’est pas renseignée.',
          'sources': [],
          'citations': [],
        },
      );
      final scroll = tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('transcript-scroll')),
          )
          .controller!;
      scroll.jumpTo(300);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('visit-question')),
        'Quel âge a la personne ?',
      );
      await tester.tap(find.byTooltip('Envoyer la question'));
      await tester.pumpAndSettle();
      expect(scroll.offset, 300);
      expect(find.byType(ActionChip), findsNothing);
    },
  );

  testWidgets(
    'failed request preserves the question, and a narrow layout stays usable',
    (tester) async {
      await mount(
        tester,
        width: 550,
        ask: (_) async => throw Exception('Offline'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('visit-question')),
        'Question à conserver',
      );
      await tester.tap(find.byTooltip('Envoyer la question'));
      await tester.pumpAndSettle();
      expect(find.text('Question à conserver'), findsOneWidget);
      expect(find.text('Réponse indisponible. Réessaie.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Transcription')).dy,
        lessThan(tester.getTopLeft(find.text('Questions sur la visite')).dy),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy speaker labels become avatars without discarding words', (
    tester,
  ) async {
    await mount(
      tester,
      data: [
        {
          'index': 0,
          'startSeconds': 0,
          'text':
              'Ergothérapeute : Avez-vous une douche ?\nVoix non identifiée : Oui, avec un seuil.',
        },
      ],
    );
    expect(find.text('Avez-vous une douche ?'), findsOneWidget);
    expect(find.text('Oui, avec un seuil.'), findsOneWidget);
    expect(find.text('👩‍⚕️'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsOneWidget);
  });

  testWidgets('workspace visual preview', (tester) async {
    await mount(
      tester,
      data: transcript.take(3).toList(),
      ask: (_) async => {
        'answer':
            'La personne marche avec une canne et souhaite rester chez elle.',
        'sources': [1],
        'citations': [
          {
            'index': 1,
            'quote': 'Je marche avec une canne et je souhaite rester chez moi.',
          },
        ],
      },
    );
    await tester.enterText(
      find.byKey(const ValueKey('visit-question')),
      'Que souhaite la personne pour son logement ?',
    );
    await tester.tap(find.byTooltip('Envoyer la question'));
    await tester.pumpAndSettle();
    if (Platform.environment['TRANSCRIPT_PREVIEW_PATH']
        case final String path) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('preview')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
  });
}
