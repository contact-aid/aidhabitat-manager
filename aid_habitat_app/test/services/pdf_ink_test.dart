import 'dart:io';

import 'package:aid_habitat_app/models/types.dart';
import 'package:aid_habitat_app/services/pdf_ink_geometry.dart';
import 'package:aid_habitat_app/services/pdf_ink_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aidhabitat/pdf_rotation');
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'local web overlays cannot be mistaken for embedded PDF annotations',
    () {
      expect(hasLocalPdfOverlays(null), isFalse);
      expect(hasLocalPdfOverlays(''), isFalse);
      expect(hasLocalPdfOverlays(' { } '), isFalse);
      expect(hasLocalPdfOverlays('{"1":"data:image/png;base64,abc"}'), isTrue);
      expect(hasLocalPdfOverlays('broken'), isTrue);
    },
  );
  test(
    'PDF canvas fits the page without encoding window margins in strokes',
    () {
      expect(
        pdfInkCanvasSize(const Size(1200, 800), 0.5, 0),
        const Size(400, 800),
      );
      expect(
        pdfInkCanvasSize(const Size(1200, 800), 0.5, 1),
        const Size(600, 1200),
      );
      expect(
        pdfInkCanvasSize(const Size(500, 900), 2, 0),
        const Size(500, 250),
      );
    },
  );
  test('legacy viewport points migrate to the visible PDF rectangle', () {
    final strokes = migrateLegacyPdfInk(
      [
        {
          'tool': 'pen',
          'color': 0xff000000,
          'strokeWidth': 2,
          'points': [
            [1 / 3, 0],
            [0.5, 0.5],
            [2 / 3, 1],
          ],
        },
      ],
      viewport: const Size(1200, 800),
      aspectRatio: 0.5,
      quarterTurns: 0,
    );
    expect(strokes.single['points'], [
      [0.0, 0.0],
      [0.5, 0.5],
      [1.0, 1.0],
    ]);
    expect(strokes.single['widthFraction'], 2 / 400);
  });
  test('invalid layout cannot silently produce misplaced PDF ink', () {
    expect(() => pdfInkCanvasSize(Size.zero, 1, 0), throwsArgumentError);
    expect(
      () => pdfInkCanvasSize(const Size(100, 100), double.nan, 0),
      throwsArgumentError,
    );
  });
  test(
    'bridge carries all pages and the total rotation without changing source',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return '/tmp/new-ink.pdf';
          });
      final result = await PdfInkService.instance.write(
        sourcePath: '/tmp/original.pdf',
        pages: {1: [], 3: []},
        quarterTurns: 5,
      );
      expect(result, '/tmp/new-ink.pdf');
      expect(calls.single.method, 'writePdfInk');
      expect(calls.single.arguments, {
        'sourcePath': '/tmp/original.pdf',
        'pages': {'1': [], '3': []},
        'quarterTurns': 1,
      });
    },
  );
  test(
    'bridge read retains editable stroke geometry and page numbers',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => {
              'pages': {
                '2': [
                  {
                    'points': [
                      [0.2, 0.3],
                    ],
                    'widthFraction': 0.01,
                    'color': 0xff111827,
                  },
                ],
              },
            },
          );
      final pages = await PdfInkService.instance.read('/tmp/file.pdf');
      expect(pages.keys, [2]);
      expect(pages[2]!.single['widthFraction'], 0.01);
    },
  );
  for (final output in [null, '', '/tmp/original.pdf']) {
    test('bridge refuses invalid export result $output', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => output);
      await expectLater(
        PdfInkService.instance.write(
          sourcePath: '/tmp/original.pdf',
          pages: {},
          quarterTurns: 0,
        ),
        throwsStateError,
      );
    });
  }
  test('native failures propagate, no successful save is fabricated', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'disk_full'),
        );
    await expectLater(
      PdfInkService.instance.write(
        sourcePath: '/tmp/original.pdf',
        pages: {},
        quarterTurns: 0,
      ),
      throwsA(isA<PlatformException>()),
    );
  });
  test('only sidecars of this exact PDF are detected', () async {
    final dir = await Directory.systemTemp.createTemp('ink-sidecar-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/file.pdf';
    await File('$path-other.page1.png.annotation.json').writeAsString('[]');
    expect(await PdfInkService.instance.hasLegacySidecars(path), isFalse);
    await File('$path.page3.png.annotation.json').writeAsString('[]');
    expect(await PdfInkService.instance.hasLegacySidecars(path), isTrue);
  });
  test(
    'PDF editor rejects a replacement but accepts hydration and own upload ACK',
    () {
      final baseline = DocItem(
        id: 'doc',
        type: 'pdf',
        name: 'file.pdf',
        title: 'file',
        date: '',
        url: '/v1',
      );
      expect(
        samePdfEditingRevision(
          baseline,
          baseline.copyWith(localPath: '/cache/v1'),
        ),
        isTrue,
      );
      expect(
        samePdfEditingRevision(baseline, baseline.copyWith(url: '/v2')),
        isFalse,
      );
      final local = baseline.copyWith(localPath: '/revision/v1');
      expect(
        samePdfEditingRevision(local, local.copyWith(url: '/uploaded/v1')),
        isTrue,
      );
      expect(
        samePdfEditingRevision(
          local,
          local.copyWith(localPath: '/revision/v2'),
        ),
        isFalse,
      );
    },
  );
}
