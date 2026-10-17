/// Languages the user can choose for voice input and spoken replies.
///
/// Whether a language really works depends on the speech engines installed
/// on the phone (usually Google's). English is nearly universal; Hausa is
/// supported only by some devices and engine versions, so the app checks the
/// installed engine and says so instead of pretending.
enum VoiceLanguage {
  english('English', 'en'),
  hausa('Hausa', 'ha');

  const VoiceLanguage(this.label, this.code);

  final String label;

  /// ISO 639-1 language code used to look for a matching engine locale.
  final String code;

  static VoiceLanguage fromName(String? name) {
    for (final VoiceLanguage l in VoiceLanguage.values) {
      if (l.name == name) return l;
    }
    return VoiceLanguage.english;
  }
}

/// User-editable voice preferences. Stored on the phone (no audio, no text).
class VoiceSettings {
  const VoiceSettings({
    this.autoSpeak = true,
    this.autoSendVoice = false,
    this.language = VoiceLanguage.english,
    this.speechRate = defaultRate,
    this.volume = defaultVolume,
  });

  /// Android's text-to-speech rate scale is 0..1 where about 0.5 is normal.
  static const double defaultRate = 0.5;
  static const double minRate = 0.2;
  static const double maxRate = 1.0;
  static const double defaultVolume = 1.0;

  /// Read each new assistant reply aloud automatically.
  final bool autoSpeak;

  /// Send a recognized phrase right away. When false (default) the text is
  /// placed in the message box so you can check it first, which matters
  /// because recognition (especially Hausa) can make mistakes.
  final bool autoSendVoice;

  final VoiceLanguage language;
  final double speechRate;
  final double volume;

  VoiceSettings copyWith({
    bool? autoSpeak,
    bool? autoSendVoice,
    VoiceLanguage? language,
    double? speechRate,
    double? volume,
  }) {
    return VoiceSettings(
      autoSpeak: autoSpeak ?? this.autoSpeak,
      autoSendVoice: autoSendVoice ?? this.autoSendVoice,
      language: language ?? this.language,
      speechRate: _clamp(speechRate ?? this.speechRate, minRate, maxRate),
      volume: _clamp(volume ?? this.volume, 0.0, 1.0),
    );
  }

  static double _clamp(double v, double lo, double hi) {
    if (v.isNaN) return lo;
    return v < lo ? lo : (v > hi ? hi : v);
  }

  @override
  bool operator ==(Object other) =>
      other is VoiceSettings &&
      other.autoSpeak == autoSpeak &&
      other.autoSendVoice == autoSendVoice &&
      other.language == language &&
      other.speechRate == speechRate &&
      other.volume == volume;

  @override
  int get hashCode =>
      Object.hash(autoSpeak, autoSendVoice, language, speechRate, volume);
}
