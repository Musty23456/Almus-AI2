import 'package:flutter/foundation.dart';

import '../models/app_settings.dart';
import '../services/settings_store.dart';

/// Holds the current connection settings and persists changes.
class SettingsController extends ValueNotifier<AppSettings> {
  SettingsController(this._store) : super(const AppSettings());

  final SettingsStore _store;

  /// Loads saved settings. Falls back to defaults (DEMO MODE) if storage fails.
  Future<void> load() async {
    try {
      value = await _store.load();
    } on Exception {
      // Keep defaults.
    }
  }

  /// Applies [settings] immediately and tries to persist them.
  /// Returns false if they could not be stored on the device.
  Future<bool> save(AppSettings settings) async {
    value = settings;
    try {
      await _store.save(settings);
      return true;
    } on Exception {
      return false;
    }
  }
}
