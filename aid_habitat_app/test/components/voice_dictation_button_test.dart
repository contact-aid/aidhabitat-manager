import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aid_habitat_app/components/voice_dictation_button.dart';

void main() {
  testWidgets('conserve le résultat final après l’arrêt du micro sur iPad', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('plugin.csdcorp.com/speech_to_text');
    const codec = StandardMethodCodec();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'locales') return ['fr_FR:Français'];
      if (call.method == 'listen') return true;
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    Future<void> notify(String method, Object value) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, value)),
        (_) {},
      );
      await tester.pump();
    }

    final controller = TextEditingController(text: 'Observation :');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: VoiceDictationButton(controller: controller)),
      ),
    );
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    await notify('notifyStatus', 'listening');
    await tester.tap(find.byType(IconButton));
    await notify('notifyStatus', 'notListening');
    await notify(
      'textRecognition',
      jsonEncode({
        'alternates': [
          {'recognizedWords': 'marche avec une canne', 'confidence': 1.0},
        ],
        'resultType': 2,
      }),
    );
    await notify('notifyStatus', 'done');
    expect(controller.text, 'Observation : marche avec une canne');
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  group('voiceDictationMessageForError', () {
    test('explains that web speech can be blocked after mic permission', () {
      expect(
        voiceDictationMessageForError('service-not-allowed', isWeb: true),
        contains('modèle vocal local'),
      );
      expect(
        voiceDictationMessageForError('not-allowed', isWeb: true),
        contains('autorisations du site'),
      );
    });

    test('identifies the browser error without exposing dictated text', () {
      expect(
        voiceDictationMessageForError('aborted', isWeb: true),
        contains('code navigateur : aborted'),
      );
      expect(
        voiceDictationMessageForError('network', isWeb: true),
        contains('service de reconnaissance vocale'),
      );
      expect(
        voiceDictationMessageForError('language-not-supported', isWeb: true),
        contains('reconnaissance française'),
      );
    });

    test('keeps native permission guidance for Apple builds', () {
      expect(
        voiceDictationMessageForError('not-allowed', isWeb: false),
        contains('Réglages'),
      );
    });
  });

  group('voiceDictationMessageForWebRuntime', () {
    test('allows local and remote browser engines', () {
      expect(voiceDictationMessageForWebRuntime('local'), isNull);
      expect(voiceDictationMessageForWebRuntime('remote'), isNull);
    });

    test('explains a failed local language installation', () {
      expect(
        voiceDictationMessageForWebRuntime('install-failed'),
        contains('module français'),
      );
    });

    test('explains a local browser preparation failure', () {
      expect(
        voiceDictationMessageForWebRuntime('local-error'),
        contains('dictée locale'),
      );
    });
  });

  group('applyVoiceDictationTranscript', () {
    test('insère la dictée à la fin avec un espace naturel', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'La personne',
          selection: TextSelection.collapsed(offset: 11),
        ),
        transcript: 'vit seule',
      );

      expect(result.text, 'La personne vit seule');
      expect(result.selection.baseOffset, result.text.length);
    });

    test('insère au curseur sans perdre le suffixe', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'La personne seule.',
          selection: TextSelection.collapsed(offset: 12),
        ),
        transcript: 'vit',
      );

      expect(result.text, 'La personne vit seule.');
      expect(result.selection.baseOffset, 16);
    });

    test('remplace la sélection courante', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'Autonomie faible',
          selection: TextSelection(baseOffset: 10, extentOffset: 16),
        ),
        transcript: 'partielle',
      );

      expect(result.text, 'Autonomie partielle');
    });

    test('les résultats partiels repartent de la même base', () {
      const base = TextEditingValue(
        text: 'Observation :',
        selection: TextSelection.collapsed(offset: 13),
      );

      final partial = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: 'marche',
      );
      final finalResult = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: 'marche avec une canne',
      );

      expect(partial.text, 'Observation : marche');
      expect(finalResult.text, 'Observation : marche avec une canne');
      expect(finalResult.text, isNot(contains('marche marche')));
    });

    test('une hypothèse vide ne supprime pas la note existante', () {
      const base = TextEditingValue(
        text: 'Texte conservé',
        selection: TextSelection.collapsed(offset: 5),
      );

      final result = applyVoiceDictationTranscript(
        baseValue: base,
        transcript: '   ',
      );

      expect(result, base);
    });

    test('la ponctuation dictée ne reçoit pas d’espace avant', () {
      final result = applyVoiceDictationTranscript(
        baseValue: const TextEditingValue(
          text: 'Besoin identifié',
          selection: TextSelection.collapsed(offset: 16),
        ),
        transcript: '.',
      );

      expect(result.text, 'Besoin identifié.');
    });
  });
}
