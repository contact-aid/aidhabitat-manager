import 'package:aid_habitat_app/services/document_scanner_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('aidhabitat/document_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <String>[];
  Object? response;
  PlatformException? error;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    calls.clear();
    response = null;
    error = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (error != null) throw error!;
      return response;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'iOS photo capture returns a local file for the existing import flow',
    () async {
      response = '/temporary/synthetic-photo.jpg';
      expect(await DocumentScannerService.instance.capturePhoto(), response);
      expect(calls, ['capturePhoto']);
    },
  );

  test(
    'cancelled or empty photo captures do not produce an import path',
    () async {
      for (final value in [null, '', '  ']) {
        response = value;
        expect(await DocumentScannerService.instance.capturePhoto(), isNull);
      }
      error = PlatformException(code: 'cancelled');
      expect(await DocumentScannerService.instance.capturePhoto(), isNull);
    },
  );

  test('camera denial is surfaced to the Documents error message', () async {
    error = PlatformException(code: 'camera_access_denied');
    await expectLater(
      DocumentScannerService.instance.capturePhoto(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'camera_access_denied',
        ),
      ),
    );
  });

  test('scanner still returns the local multipage PDF result', () async {
    response = {
      'path': '/temporary/synthetic-scan.pdf',
      'fileName': 'synthetic-scan.pdf',
      'mimeType': 'application/pdf',
      'pageCount': 2,
    };
    final scan = await DocumentScannerService.instance.scanToPdf();
    expect(scan!.path, '/temporary/synthetic-scan.pdf');
    expect(scan.pageCount, 2);
    expect(calls, ['scanDocument']);
  });

  test('scanner cancellation produces no file', () async {
    error = PlatformException(code: 'cancelled');
    expect(await DocumentScannerService.instance.scanToPdf(), isNull);
  });

  test('non-iOS platforms do not invoke native capture', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(await DocumentScannerService.instance.capturePhoto(), isNull);
    expect(await DocumentScannerService.instance.scanToPdf(), isNull);
    expect(calls, isEmpty);
  });
}
