import 'package:shared_preferences/shared_preferences.dart';

/// Remembers that the user understood how voice input works before the
/// microphone was used for the first time.
abstract class VoiceConsentStore {
  Future<bool> isGranted();
  Future<void> setGranted(bool value);
}

class PrefsVoiceConsentStore implements VoiceConsentStore {
  const PrefsVoiceConsentStore();

  static const String _key = 'voice_consent_v1';

  @override
  Future<bool> isGranted() async =>
      (await SharedPreferences.getInstance()).getBool(_key) ?? false;

  @override
  Future<void> setGranted(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(_key, value);
}

class MemoryVoiceConsentStore implements VoiceConsentStore {
  MemoryVoiceConsentStore({this.granted = false});

  bool granted;

  @override
  Future<bool> isGranted() async => granted;

  @override
  Future<void> setGranted(bool value) async => granted = value;
}

/// What the first-use dialog says. ALMUS AI itself never records audio; the
/// phone's speech service listens and may process audio online.
const String kVoiceConsentText =
    'Voice input uses your phone\'s speech service (for example Speech Services by Google). '
    'ALMUS AI does not record, store or upload your voice: it only receives the recognized text. '
    'The speech service itself may send audio to its provider to turn it into text, depending on your phone and its settings. '
    'The microphone opens only after you tap it, and closes when you stop, cancel, or leave the chat.';
