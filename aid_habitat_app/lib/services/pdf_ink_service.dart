import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

bool hasLocalPdfOverlays(String? value) {
  if (value == null || value.trim().isEmpty) return false;
  try {
    final decoded = jsonDecode(value);
    return decoded is! Map || decoded.isNotEmpty;
  } catch (_) {
    return true;
  }
}

class PdfInkService {
  PdfInkService._();
  static final instance = PdfInkService._();
  static const _channel = MethodChannel('aidhabitat/pdf_rotation');

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<bool> hasLegacySidecars(String sourcePath) async {
    if (kIsWeb || sourcePath.isEmpty) return false;
    final file = File(sourcePath);
    if (!await file.parent.exists()) return false;
    final pattern = RegExp(
      '^${RegExp.escape(p.basename(sourcePath))}\\.page[0-9]+\\.png\\.annotation\\.json\$',
    );
    await for (final entry in file.parent.list(followLinks: false)) {
      if (entry is File && pattern.hasMatch(p.basename(entry.path))) {
        return true;
      }
    }
    return false;
  }

  Future<Map<int, List<Map<String, dynamic>>>> read(String sourcePath) async {
    final raw = await _channel.invokeMethod<Object>('readPdfInk', {
      'sourcePath': sourcePath,
    });
    if (raw == null) {
      throw StateError('Lecture des annotations PDF indisponible');
    }
    final decoded = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
    return (decoded['pages'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(
        int.parse(key),
        (value as List).cast<Map<String, dynamic>>(),
      ),
    );
  }

  Future<String> write({
    required String sourcePath,
    required Map<int, List<Map<String, dynamic>>> pages,
    required int quarterTurns,
  }) async {
    final path = await _channel.invokeMethod<String>('writePdfInk', {
      'sourcePath': sourcePath,
      'pages': pages.map((page, strokes) => MapEntry('$page', strokes)),
      'quarterTurns': quarterTurns % 4,
    });
    if (path == null || path.isEmpty || path == sourcePath) {
      throw StateError("Le PDF annote n'a pas ete produit");
    }
    return path;
  }

  Future<String> render({
    required String sourcePath,
    required int page,
    required double width,
    bool omitManagedInk = false,
  }) async {
    final path = await _channel.invokeMethod<String>('renderPdfInkPreview', {
      'sourcePath': sourcePath,
      'page': page,
      'width': width,
      'omitManagedInk': omitManagedInk,
    });
    if (path == null || path.isEmpty) {
      throw StateError('Rendu PDF indisponible');
    }
    return path;
  }
}
