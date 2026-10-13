import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_settings.dart';

/// Where voice preferences are kept between launches.
abstract class VoiceSettingsStore {
  Future<VoiceSettings> load();
  Future<void> save(VoiceSettings settings);
}

/// App-private preferences. Only switches and numbers are stored: never audio
/// and never recognized text.
class PrefsVoiceSettingsStore implements VoiceSettingsStore {
  static const String _autoSpeak = 'voice_auto_speak';
  static const String _autoSend = 'voice_auto_send';
  static const String _language = 'voice_language';
  static const String _rate = 'voice_rate';
  static const String _volume = 'voice_volume';

  @override
  Future<VoiceSettings> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return const VoiceSettings().copyWith(
      autoSpeak: p.getBool(_autoSpeak),
      autoSendVoice: p.getBool(_autoSend),
      language: VoiceLanguage.fromName(p.getString(_language)),
      speechRate: p.getDouble(_rate),
      volume: p.getDouble(_volume),
    );
  }

  @override
  Future<void> save(VoiceSettings s) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_autoSpeak, s.autoSpeak);
    await p.setBool(_autoSend, s.autoSendVoice);
    await p.setString(_language, s.language.name);
    await p.setDouble(_rate, s.speechRate);
    await p.setDouble(_volume, s.volume);
  }
}

/// In-memory store used by tests.
class MemoryVoiceSettingsStore implements VoiceSettingsStore {
  MemoryVoiceSettingsStore([this.settings = const VoiceSettings()]);

  VoiceSettings settings;

  @override
  Future<VoiceSettings> load() async => settings;

  @override
  Future<void> save(VoiceSettings settings) async => this.settings = settings;
}

/// Holds the current voice settings and persists changes.
class VoiceSettingsController extends ValueNotifier<VoiceSettings> {
  VoiceSettingsController(this._store) : super(const VoiceSettings());

  final VoiceSettingsStore _store;

  Future<void> load() async {
    try {
      value = await _store.load();
    } on Exception {
      // Keep defaults.
    }
  }

  /// Applies [settings] immediately; returns false if they could not be stored.
  Future<bool> save(VoiceSettings settings) async {
    value = settings;
    try {
      await _store.save(settings);
      return true;
    } on Exception {
      return false;
    }
  }
}
