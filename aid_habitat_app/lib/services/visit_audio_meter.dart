import 'dart:math' as math;

/// Decodes native meter snapshots while retaining exactly four voice samples.
/// The history has a fixed length: shift its values, never remove/add entries.

class VisitAudioMeter {
  /// Display gain only: the recorded audio is never amplified or altered.
  /// At/below -60 dB the bar is a dot; normal speech grows visibly to 20 px.
  static double barHeight(double level) {
    if (!level.isFinite || level <= 0.001) return 3.5;
    final decibels = 20 * math.log(level) / math.ln10;
    final amplitude = ((decibels + 60) / 24).clamp(0.0, 1.0);
    return 3.5 + 16.5 * math.sqrt(amplitude);
  }

  final List<double> _levels = List<double>.filled(4, 0);
  List<double> get levels => List<double>.unmodifiable(_levels);
  double level = 0;
  double duration = 0;
  bool active = false;
  bool interrupted = false;

  void reset() {
    _levels.fillRange(0, 4, 0);
    level = 0;
    duration = 0;
    active = false;
    interrupted = false;
  }

  void update(Map<String, dynamic> snapshot) {
    final rawLevel = snapshot['level'];
    final rawDuration = snapshot['duration'];
    if (snapshot['active'] is! bool ||
        rawLevel is! num ||
        !rawLevel.isFinite ||
        rawDuration is! num ||
        !rawDuration.isFinite ||
        rawDuration < 0) {
      throw const FormatException('État du microphone invalide.');
    }
    level = rawLevel.toDouble().clamp(0.0, 1.0);
    duration = rawDuration.toDouble();
    active = snapshot['active'] as bool;
    interrupted = snapshot['interrupted'] == true;
    for (var i = 0; i < _levels.length - 1; i++) {
      _levels[i] = _levels[i + 1];
    }
    _levels[_levels.length - 1] = level;
  }
}
