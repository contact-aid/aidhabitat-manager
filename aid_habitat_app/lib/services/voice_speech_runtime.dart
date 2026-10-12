import 'voice_speech_runtime_io.dart'
    if (dart.library.html) 'voice_speech_runtime_web.dart';

const webVoiceRuntimeLocal = 'local';
const webVoiceRuntimeRemote = 'remote';
const webVoiceRuntimeRemoteTrack = 'remote-track';
const webVoiceRuntimeUnsupported = 'unsupported';
const webVoiceRuntimeInstallFailed = 'install-failed';
const webVoiceRuntimeLocalError = 'local-error';

/// Selects an already-installed browser language pack when available, otherwise
/// the browser's default recognition service. The bridge applies this choice
/// to the retained recognition object on its next start.
Future<String> prepareWebVoiceSpeechRuntime() {
  return prepareWebVoiceSpeechRuntimeImpl();
}
