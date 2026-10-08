import 'dart:ui' show PointerDeviceKind;

import 'package:aid_habitat_app/components/notes_widget.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iPad drawing accepts Pencil and rejects finger and palm contacts', () {
    expect(
      isNoteCanvasPointerAllowed(
        PointerDeviceKind.stylus,
        platform: TargetPlatform.iOS,
      ),
      isTrue,
    );
    expect(
      isNoteCanvasPointerAllowed(
        PointerDeviceKind.invertedStylus,
        platform: TargetPlatform.iOS,
      ),
      isTrue,
    );
    expect(
      isNoteCanvasPointerAllowed(
        PointerDeviceKind.touch,
        platform: TargetPlatform.iOS,
      ),
      isFalse,
    );
    expect(
      isNoteCanvasPointerAllowed(
        PointerDeviceKind.mouse,
        platform: TargetPlatform.iOS,
      ),
      isFalse,
    );
  });

  test('Mac drawing keeps mouse and touch input', () {
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      expect(
        isNoteCanvasPointerAllowed(kind, platform: TargetPlatform.macOS),
        isTrue,
      );
    }
  });
}
