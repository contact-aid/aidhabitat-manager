import 'package:flutter_test/flutter_test.dart';
import 'package:aid_habitat_app/services/visit_audio_meter.dart';

void main() {
  test('native meter refresh can run continuously with exactly four bars', () {
    final meter = VisitAudioMeter();
    for (var tick = 0; tick < 1200; tick++) {
      expect(
        () => meter.update({
          'active': true,
          'interrupted': false,
          'level': (tick % 10) / 10,
          'duration': tick / 10,
        }),
        returnsNormally,
      );
      expect(meter.levels, hasLength(4));
    }
    expect(meter.levels, [0.6, 0.7, 0.8, 0.9]);
    expect(meter.duration, 119.9);
    expect(meter.active, isTrue);
    meter.update({
      'active': false,
      'interrupted': true,
      'level': 0,
      'duration': 120,
    });
    expect(meter.active, isFalse);
    expect(meter.interrupted, isTrue);
    meter.reset();
    expect(meter.levels, [0, 0, 0, 0]);
  });

  test('a malformed snapshot cannot be mistaken for a stopped recording', () {
    final meter = VisitAudioMeter();
    meter.update({'active': true, 'level': 0.5, 'duration': 5});
    expect(() => meter.update({}), throwsFormatException);
    expect(meter.active, isTrue);
    expect(
      () => meter.update({'active': true, 'level': double.nan, 'duration': 6}),
      throwsFormatException,
    );
    expect(meter.levels.last, 0.5);
  });
}
