import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

/// App'Ergo works in landscape on iPad, whatever the system rotation lock says.
///
/// Portrait stays declared in Info.plist on purpose: iOS could not rotate the
/// native scanner otherwise. Only the Flutter screens are restricted here, so
/// leaving the scanner brings the iPad back to landscape on its own.
Future<void> applyAppOrientationPolicy() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
  try {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  } on PlatformException catch (error) {
    // Orientation is comfort, not data: never block startup over it.
    debugPrint('[orientation] paysage non appliqué : ${error.message}');
  }
}
