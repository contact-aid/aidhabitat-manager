import 'package:aid_habitat_app/services/connectivity_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final network in ['wifi', 'ethernet', 'mobile', 'none']) {
    test('audio transfer policy on $network', () async {
      final service = ConnectivityService();
      service.dispose();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (_) async => [network],
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
        (_) async => null,
      );
      await service.initialize();
      expect(service.isUnmetered, network == 'wifi' || network == 'ethernet');
      expect(service.isOffline, network == 'none');
      service.dispose();
    });
  }
}
