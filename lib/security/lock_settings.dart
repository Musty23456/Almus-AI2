import 'package:shared_preferences/shared_preferences.dart';

/// How long the app may stay in the background before it locks again.
enum AutoLockDelay {
  immediately('Immediately', Duration.zero),
  after15Seconds('After 15 seconds', Duration(seconds: 15)),
  after1Minute('After 1 minute', Duration(minutes: 1)),
  after5Minutes('After 5 minutes', Duration(minutes: 5));

  const AutoLockDelay(this.label, this.duration);

  final String label;
  final Duration duration;

  static AutoLockDelay fromName(String? name) {
    for (final AutoLockDelay d in AutoLockDelay.values) {
      if (d.name == name) return d;
    }
    // Unknown or missing: the safest choice.
    return AutoLockDelay.immediately;
  }
}

/// User-editable security preferences. They are only switches and a delay:
/// no secret, no biometric data and no PIN is ever stored here.
class LockSettings {
  const LockSettings({
    this.enabled = true,
    this.autoLock = AutoLockDelay.immediately,
    this.allowDeviceCredential = true,
  });

  /// Require Android authentication to open the app. On by default.
  final bool enabled;

  final AutoLockDelay autoLock;

  /// Offer the phone's PIN/pattern/password next to the biometric.
  final bool allowDeviceCredential;

  LockSettings copyWith({
    bool? enabled,
    AutoLockDelay? autoLock,
    bool? allowDeviceCredential,
  }) {
    return LockSettings(
      enabled: enabled ?? this.enabled,
      autoLock: autoLock ?? this.autoLock,
      allowDeviceCredential:
          allowDeviceCredential ?? this.allowDeviceCredential,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LockSettings &&
      other.enabled == enabled &&
      other.autoLock == autoLock &&
      other.allowDeviceCredential == allowDeviceCredential;

  @override
  int get hashCode => Object.hash(enabled, autoLock, allowDeviceCredential);
}

/// Where lock preferences are kept between launches.
abstract class LockSettingsStore {
  Future<LockSettings> load();
  Future<void> save(LockSettings settings);
}

/// App-private preferences.
class PrefsLockSettingsStore implements LockSettingsStore {
  static const String _enabled = 'lock_enabled';
  static const String _delay = 'lock_auto_lock';
  static const String _fallback = 'lock_allow_device_credential';

  @override
  Future<LockSettings> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return LockSettings(
      enabled: p.getBool(_enabled) ?? true,
      autoLock: AutoLockDelay.fromName(p.getString(_delay)),
      allowDeviceCredential: p.getBool(_fallback) ?? true,
    );
  }

  @override
  Future<void> save(LockSettings s) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_enabled, s.enabled);
    await p.setString(_delay, s.autoLock.name);
    await p.setBool(_fallback, s.allowDeviceCredential);
  }
}

/// In-memory store used by tests.
class MemoryLockSettingsStore implements LockSettingsStore {
  MemoryLockSettingsStore([this.settings = const LockSettings()]);

  LockSettings settings;
  int saves = 0;

  @override
  Future<LockSettings> load() async => settings;

  @override
  Future<void> save(LockSettings settings) async {
    saves++;
    this.settings = settings;
  }
}
