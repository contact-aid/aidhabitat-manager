Future<Map<String, dynamic>> localAiStatus() async => {'supported': false};
Future<void> prepareLocalAi() async => throw UnsupportedError('Web only');
Future<String> rewriteLocalAi(String text, String mode) async =>
    throw UnsupportedError('Web only');
double localAiProgress() => 0;
void cancelLocalAi() {}
