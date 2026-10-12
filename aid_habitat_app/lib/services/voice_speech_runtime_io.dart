Future<String> prepareWebVoiceSpeechRuntimeImpl() async => 'remote';

void startWebVoiceRecognition({
  required void Function(String) onResult,
  required void Function(String) onStatus,
  required void Function(String) onError,
}) => throw UnsupportedError('Web dictation is only available on the web');
void stopWebVoiceRecognition() {}
void cancelWebVoiceRecognition() {}
