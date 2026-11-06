import 'package:aid_habitat_app/services/app_orientation_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final requested = <Object?>[];

  setUp(() {
    requested.clear();
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        requested.add(call.arguments);
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('iOS restricts the Flutter screens to both landscape sides', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await applyAppOrientationPolicy();
    expect(requested, [
      ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight'],
    ]);
  });

  test('other platforms keep their orientation behaviour', () async {
    for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
      debugDefaultTargetPlatformOverride = platform;
      await applyAppOrientationPolicy();
    }
    expect(requested, isEmpty);
  });
}
