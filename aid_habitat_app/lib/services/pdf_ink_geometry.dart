import 'dart:ui';
import '../models/types.dart';

bool samePdfEditingRevision(DocItem baseline, DocItem current) {
  if (baseline.id != current.id) return false;
  if ((baseline.localPath ?? '').isNotEmpty) {
    return baseline.localPath == current.localPath;
  }
  return baseline.url == current.url && baseline.dataUrl == current.dataUrl;
}

Size pdfInkCanvasSize(Size viewport, double aspectRatio, int quarterTurns) {
  final surface = quarterTurns.isOdd
      ? Size(viewport.height, viewport.width)
      : viewport;
  if (!aspectRatio.isFinite ||
      aspectRatio <= 0 ||
      surface.width <= 0 ||
      surface.height <= 0) {
    throw ArgumentError('Invalid PDF canvas dimensions');
  }
  return surface.width / surface.height > aspectRatio
      ? Size(surface.height * aspectRatio, surface.height)
      : Size(surface.width, surface.width / aspectRatio);
}

/// Legacy sidecars describe the full viewport, including BoxFit.contain
/// margins. Preserve their current visible placement when moving to page space.
List<Map<String, dynamic>> migrateLegacyPdfInk(
  List<Map<String, dynamic>> strokes, {
  required Size viewport,
  required double aspectRatio,
  required int quarterTurns,
}) {
  final surface = quarterTurns.isOdd
      ? Size(viewport.height, viewport.width)
      : viewport;
  final page = pdfInkCanvasSize(viewport, aspectRatio, quarterTurns);
  final left = (surface.width - page.width) / 2;
  final top = (surface.height - page.height) / 2;
  return strokes
      .map(
        (stroke) => {
          ...stroke,
          'widthFraction':
              (stroke['strokeWidth'] as num).toDouble() / page.width,
          'points': (stroke['points'] as List).map((raw) {
            final pair = raw as List;
            return [
              ((pair[0] as num).toDouble() * surface.width - left) / page.width,
              ((pair[1] as num).toDouble() * surface.height - top) /
                  page.height,
            ];
          }).toList(),
        },
      )
      .toList();
}
