import 'voice_speech_runtime_io.dart'
    if (dart.library.html) 'voice_speech_runtime_web.dart';
export 'voice_speech_runtime_io.dart'
    if (dart.library.html) 'voice_speech_runtime_web.dart'
    show
        startWebVoiceRecognition,
        stopWebVoiceRecognition,
        cancelWebVoiceRecognition;

const webVoiceRuntimeLocal = 'local';
const webVoiceRuntimeRemote = 'remote';
const webVoiceRuntimeRemoteTrack = 'remote-track';
const webVoiceRuntimeUnsupported = 'unsupported';
const webVoiceRuntimeInstallFailed = 'install-failed';
const webVoiceRuntimeLocalError = 'local-error';

/// Selects the local WASM model on supported browsers. Legacy browsers may
/// use their built-in speech service when audio recording is unavailable.
Future<String> prepareWebVoiceSpeechRuntime() {
  return prepareWebVoiceSpeechRuntimeImpl();
}
