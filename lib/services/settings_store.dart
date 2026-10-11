import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';

/// Where connection settings are kept between app launches.
abstract class SettingsStore {
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// Stores settings in the app's private storage on the device.
/// Note: the access token is stored unencrypted in app-private storage.
class PrefsSettingsStore implements SettingsStore {
  static const String _urlKey = 'backend_url';
  static const String _tokenKey = 'access_token';

  @override
  Future<AppSettings> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return AppSettings(
      backendUrl: prefs.getString(_urlKey) ?? '',
      accessToken: prefs.getString(_tokenKey) ?? '',
    );
  }

  @override
  Future<void> save(AppSettings settings) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, settings.backendUrl);
    await prefs.setString(_tokenKey, settings.accessToken);
  }
}

/// In-memory store used by tests.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.settings = const AppSettings()]);

  AppSettings settings;

  @override
  Future<AppSettings> load() async => settings;

  @override
  Future<void> save(AppSettings settings) async => this.settings = settings;
}
