import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:aid_habitat_app/services/data_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('forcing a remote reread while offline fails immediately', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (_) async => ['none'],
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
      (_) async => null,
    );
    await ConnectivityService().initialize();
    addTearDown(() => ConnectivityService().dispose());

    await expectLater(
      DataService().forceResyncFromRemote(),
      throwsA(isA<ForceResyncUnavailableException>()),
    );
  });
}
