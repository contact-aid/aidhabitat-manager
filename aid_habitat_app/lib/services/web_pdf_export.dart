import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'web_pdf_export_io.dart'
    if (dart.library.html) 'web_pdf_export_web.dart'
    as platform;

class WebPdfPageSnapshot {
  const WebPdfPageSnapshot(this.bytes, {this.legacyViewport = false});
  final Uint8List bytes;
  final bool legacyViewport;
}

Map<int, WebPdfPageSnapshot> decodeWebPdfOverlays(String? raw) {
  if (raw == null || raw.trim().isEmpty) return {};
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw const FormatException('Annotations PDF illisibles');
  }
  final result = <int, WebPdfPageSnapshot>{};
  for (final entry in decoded.entries) {
    final key = entry.key.toString();
    final value = entry.value;
    if (!RegExp(r'^[1-9][0-9]*$').hasMatch(key) ||
        value is! String ||
        !value.startsWith('data:image/png;base64,')) {
      throw const FormatException(
        'Annotation PDF invalide : original conserve',
      );
    }
    final bytes = base64Decode(
      value.substring('data:image/png;base64,'.length),
    );
    if (bytes.length < 8 ||
        !List.generate(8, (i) => bytes[i]).asMap().entries.every(
          (e) => e.value == const [137, 80, 78, 71, 13, 10, 26, 10][e.key],
        )) {
      throw const FormatException('Image annotee invalide');
    }
    result[int.parse(key)] = WebPdfPageSnapshot(bytes, legacyViewport: true);
  }
  return result;
}

/// Historical screenshots included centered BoxFit.contain margins. Crop only
/// those margins before editing in page coordinates; keep the original in DB
/// until the complete PDF has been durably published.
Future<Uint8List> normalizeLegacyWebPdfPage(
  Uint8List bytes,
  double pageAspect,
) async {
  if (!pageAspect.isFinite || pageAspect <= 0) {
    throw ArgumentError('Dimensions PDF invalides');
  }
  final codec = await ui.instantiateImageCodec(bytes);
  ui.Image? image;
  ui.Image? cropped;
  ui.Picture? picture;
  try {
    image = (await codec.getNextFrame()).image;
    final w = image.width.toDouble(), h = image.height.toDouble();
    final width = w / h > pageAspect ? h * pageAspect : w;
    final height = w / h > pageAspect ? h : w / pageAspect;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final scale = 4096 / (width > height ? width : height);
    final boundedScale = scale < 1 ? scale : 1.0;
    final outputWidth = (width * boundedScale).round().clamp(1, 4096);
    final outputHeight = (height * boundedScale).round().clamp(1, 4096);
    canvas.drawImageRect(
      image,
      ui.Rect.fromLTWH((w - width) / 2, (h - height) / 2, width, height),
      ui.Rect.fromLTWH(0, 0, outputWidth.toDouble(), outputHeight.toDouble()),
      ui.Paint(),
    );
    picture = recorder.endRecording();
    cropped = await picture.toImage(outputWidth, outputHeight);
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('Conversion des annotations impossible');
    return data.buffer.asUint8List();
  } finally {
    cropped?.dispose();
    picture?.dispose();
    image?.dispose();
    codec.dispose();
  }
}

Future<void> prepareWebPdfExport() => platform.prepareWebPdfExport();

Future<Uint8List> exportWebPdf({
  required Uint8List source,
  required Map<int, WebPdfPageSnapshot> pages,
  int quarterTurns = 0,
}) => platform.exportWebPdfImpl(
  source,
  pages.map(
    (number, snapshot) => MapEntry('$number', {
      'bytes': snapshot.bytes,
      'legacyViewport': snapshot.legacyViewport,
    }),
  ),
  quarterTurns,
);
