import 'dart:async';
import 'dart:typed_data';

import 'package:aid_habitat_app/services/image_compression_worker.dart';
import 'package:aid_habitat_app/services/image_compressor.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  late Uint8List largeJpeg;
  late Uint8List detailedPng;

  setUpAll(() {
    final large = _syntheticImage(1800, 1000);
    largeJpeg = Uint8List.fromList(img.encodeJpg(large, quality: 100));
    detailedPng = Uint8List.fromList(
      img.encodePng(_syntheticNoiseImage(640, 420)),
    );
  });

  test('preserves a JPEG below the skip threshold', () async {
    final bytes = Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9]);

    final before = await _legacyCompressImageForUpload(
      bytes: bytes,
      fileName: 'small.JPEG',
      sourceMimeType: 'IMAGE/JPEG',
    );
    final after = await compressImageForUpload(
      bytes: bytes,
      fileName: 'small.JPEG',
      sourceMimeType: 'IMAGE/JPEG',
    );

    _expectSameResult(after, before);
    expect(after.bytes, orderedEquals(bytes));
    expect(after.mimeType, 'image/jpeg');
    expect(after.fileName, 'small.JPEG');
    expect(after.wasRecompressed, isFalse);
  });

  test(
    'resizes a large image and preserves output metadata semantics',
    () async {
      final before = await _legacyCompressImageForUpload(
        bytes: largeJpeg,
        fileName: 'visite.original.jpeg',
        sourceMimeType: 'image/jpeg',
        maxWidthPx: 900,
        jpegQuality: 80,
        skipThresholdBytes: 0,
      );
      final after = await compressImageForUpload(
        bytes: largeJpeg,
        fileName: 'visite.original.jpeg',
        sourceMimeType: 'image/jpeg',
        maxWidthPx: 900,
        jpegQuality: 80,
        skipThresholdBytes: 0,
      );

      _expectSameResult(after, before);
      expect(after.wasRecompressed, isTrue);
      expect(after.mimeType, 'image/jpeg');
      expect(after.fileName, 'visite.original.jpg');
      expect(img.decodeImage(after.bytes)?.width, 900);
    },
  );

  test(
    'recompresses a detailed PNG with coherent bytes, MIME and extension',
    () async {
      final before = await _legacyCompressImageForUpload(
        bytes: detailedPng,
        fileName: 'sanitaires.png',
        sourceMimeType: 'image/png',
        maxWidthPx: 480,
      );
      final after = await compressImageForUpload(
        bytes: detailedPng,
        fileName: 'sanitaires.png',
        sourceMimeType: 'image/png',
        maxWidthPx: 480,
      );

      _expectSameResult(after, before);
      expect(after.wasRecompressed, isTrue);
      expect(after.mimeType, 'image/jpeg');
      expect(after.fileName, 'sanitaires.jpg');
      expect(after.bytes.take(2), orderedEquals(<int>[0xff, 0xd8]));
    },
  );

  for (final fastResize in <bool>[false, true]) {
    test(
      'fastResize=$fastResize matches the previous interpolation output',
      () async {
        final before = await _legacyCompressImageForUpload(
          bytes: largeJpeg,
          fileName: 'accessibilite.jpg',
          sourceMimeType: 'image/jpeg',
          maxWidthPx: 700,
          jpegQuality: 76,
          skipThresholdBytes: 0,
          fastResize: fastResize,
        );
        final after = await compressImageForUpload(
          bytes: largeJpeg,
          fileName: 'accessibilite.jpg',
          sourceMimeType: 'image/jpeg',
          maxWidthPx: 700,
          jpegQuality: 76,
          skipThresholdBytes: 0,
          fastResize: fastResize,
        );

        _expectSameResult(after, before);
        expect(img.decodeImage(after.bytes)?.width, 700);
      },
    );
  }

  test('falls back unchanged when supported data cannot be decoded', () async {
    final bytes = Uint8List.fromList(
      List<int>.generate(128, (index) => (index * 37) & 0xff),
    );

    final before = await _legacyCompressImageForUpload(
      bytes: bytes,
      fileName: 'corrupted.jpg',
      sourceMimeType: 'image/jpeg',
      skipThresholdBytes: 0,
    );
    final after = await compressImageForUpload(
      bytes: bytes,
      fileName: 'corrupted.jpg',
      sourceMimeType: 'image/jpeg',
      skipThresholdBytes: 0,
    );

    _expectSameResult(after, before);
    expect(after.bytes, orderedEquals(bytes));
    expect(after.wasRecompressed, isFalse);
  });

  test('leaves an unsupported document unchanged', () async {
    final bytes = Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46]);
    final before = await _legacyCompressImageForUpload(
      bytes: bytes,
      fileName: 'devis sdb.pdf',
      sourceMimeType: 'application/pdf',
      skipThresholdBytes: 0,
    );
    final after = await compressImageForUpload(
      bytes: bytes,
      fileName: 'devis sdb.pdf',
      sourceMimeType: 'application/pdf',
      skipThresholdBytes: 0,
    );

    _expectSameResult(after, before);
    expect(identical(after.bytes, bytes), isTrue);
    expect(after.wasRecompressed, isFalse);
  });

  test('preserves the original when the worker throws', () async {
    expect(
      () => compressImageInWorker(
        ImageCompressionWorkerRequest(
          bytes: detailedPng,
          maxWidthPx: -1,
          jpegQuality: 80,
          fastResize: false,
        ),
      ),
      throwsRangeError,
    );
    final before = await _legacyCompressImageForUpload(
      bytes: detailedPng,
      fileName: 'original.png',
      sourceMimeType: 'image/png',
      maxWidthPx: -1,
    );
    final after = await compressImageForUpload(
      bytes: detailedPng,
      fileName: 'original.png',
      sourceMimeType: 'image/png',
      maxWidthPx: -1,
    );

    _expectSameResult(after, before);
    expect(identical(after.bytes, detailedPng), isTrue);
    expect(after.wasRecompressed, isFalse);
  });

  test('keeps a PNG when JPEG encoding would be larger', () async {
    final bytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 1, height: 1)),
    );

    final before = await _legacyCompressImageForUpload(
      bytes: bytes,
      fileName: 'pixel.png',
      sourceMimeType: 'image/png',
    );
    final after = await compressImageForUpload(
      bytes: bytes,
      fileName: 'pixel.png',
      sourceMimeType: 'image/png',
    );

    _expectSameResult(after, before);
    expect(after.bytes, orderedEquals(bytes));
    expect(after.mimeType, 'image/png');
    expect(after.fileName, 'pixel.png');
    expect(after.wasRecompressed, isFalse);
  });

  test(
    'reports total time separately from native caller responsiveness',
    () async {
      final legacyWatch = Stopwatch()..start();
      final before = await _legacyCompressImageForUpload(
        bytes: largeJpeg,
        fileName: 'timing.jpg',
        sourceMimeType: 'image/jpeg',
        maxWidthPx: 800,
        skipThresholdBytes: 0,
      );
      legacyWatch.stop();

      var callerTicks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => callerTicks++,
      );
      final workerWatch = Stopwatch()..start();
      late CompressedImage after;
      try {
        after = await compressImageForUpload(
          bytes: largeJpeg,
          fileName: 'timing.jpg',
          sourceMimeType: 'image/jpeg',
          maxWidthPx: 800,
          skipThresholdBytes: 0,
        );
      } finally {
        workerWatch.stop();
        timer.cancel();
      }

      _expectSameResult(after, before);
      // ignore: avoid_print
      print(
        '[image-compression-measure] legacy_total_ms='
        '${legacyWatch.elapsedMilliseconds} worker_total_ms='
        '${workerWatch.elapsedMilliseconds} caller_ticks=$callerTicks',
      );
      if (!kIsWeb) {
        expect(callerTicks, greaterThan(0));
      }
    },
  );
}

img.Image _syntheticImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgba(
        x,
        y,
        (x * 13 + y * 3) & 0xff,
        (x * 5 + y * 17) & 0xff,
        (x * 19 + y * 7) & 0xff,
        0xff,
      );
    }
  }
  return image;
}

img.Image _syntheticNoiseImage(int width, int height) {
  final image = img.Image(width: width, height: height);
  var state = 0x12345678;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      state = (1664525 * state + 1013904223) & 0xffffffff;
      image.setPixelRgba(
        x,
        y,
        state & 0xff,
        (state >> 8) & 0xff,
        (state >> 16) & 0xff,
        0xff,
      );
    }
  }
  return image;
}

void _expectSameResult(CompressedImage actual, CompressedImage expected) {
  expect(actual.bytes, orderedEquals(expected.bytes));
  expect(actual.mimeType, expected.mimeType);
  expect(actual.fileName, expected.fileName);
  expect(actual.wasRecompressed, expected.wasRecompressed);
}

/// Snapshot de l'implémentation synchrone avant F12, utilisée seulement comme
/// oracle de non-régression sur les mêmes entrées synthétiques.
Future<CompressedImage> _legacyCompressImageForUpload({
  required Uint8List bytes,
  required String fileName,
  String? sourceMimeType,
  int maxWidthPx = 1600,
  int jpegQuality = 80,
  int skipThresholdBytes = 200 * 1024,
  bool fastResize = false,
}) async {
  final lowerName = fileName.toLowerCase();
  final originalMime = (sourceMimeType ?? '').toLowerCase();
  final isJpeg =
      originalMime == 'image/jpeg' ||
      lowerName.endsWith('.jpg') ||
      lowerName.endsWith('.jpeg');
  final isPng = originalMime == 'image/png' || lowerName.endsWith('.png');
  final isHeic =
      originalMime.startsWith('image/heic') ||
      originalMime.startsWith('image/heif') ||
      lowerName.endsWith('.heic') ||
      lowerName.endsWith('.heif');
  final isWebp = originalMime == 'image/webp' || lowerName.endsWith('.webp');
  final isBmp = originalMime == 'image/bmp' || lowerName.endsWith('.bmp');
  final isGif = originalMime == 'image/gif' || lowerName.endsWith('.gif');
  final supported = isJpeg || isPng || isHeic || isWebp || isBmp || isGif;

  if (!supported) {
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty
          ? originalMime
          : 'application/octet-stream',
      fileName: fileName,
      wasRecompressed: false,
    );
  }
  if (!isPng && bytes.length < skipThresholdBytes) {
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
      fileName: fileName,
      wasRecompressed: false,
    );
  }

  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return CompressedImage(
        bytes: bytes,
        mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
        fileName: fileName,
        wasRecompressed: false,
      );
    }

    img.Image working = decoded;
    if (working.width > maxWidthPx) {
      working = img.copyResize(
        working,
        width: maxWidthPx,
        interpolation: fastResize
            ? img.Interpolation.linear
            : img.Interpolation.cubic,
      );
    }
    final result = Uint8List.fromList(
      img.encodeJpg(working, quality: jpegQuality),
    );
    if (result.length >= bytes.length) {
      return CompressedImage(
        bytes: bytes,
        mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
        fileName: fileName,
        wasRecompressed: false,
      );
    }

    final dotIndex = fileName.lastIndexOf('.');
    final newFileName = dotIndex > 0
        ? '${fileName.substring(0, dotIndex)}.jpg'
        : '$fileName.jpg';
    return CompressedImage(
      bytes: result,
      mimeType: 'image/jpeg',
      fileName: newFileName,
      wasRecompressed: true,
    );
  } catch (_) {
    return CompressedImage(
      bytes: bytes,
      mimeType: originalMime.isNotEmpty ? originalMime : 'image/jpeg',
      fileName: fileName,
      wasRecompressed: false,
    );
  }
}
