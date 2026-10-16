import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the user chose about which AI provider answers and when another one may help (Phase 4).
///
/// Privacy defaults: automatic fallback is OFF, and even when on it only reaches providers the
/// user ticked. Memory notes and attached-file text are withheld from a fallback provider unless
/// the user allowed them separately. The backend enforces all of this too.
class RoutingPreferences {
  const RoutingPreferences({
    this.preferredProvider,
    this.models = const <String, String>{},
    this.fallbackEnabled = false,
    this.fallbackProviders = const <String>{},
    this.shareMemoryWithFallback = false,
    this.shareFilesWithFallback = false,
  });

  factory RoutingPreferences.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const RoutingPreferences();
    final Object? models = json['models'];
    final Object? providers = json['fallbackProviders'];
    return RoutingPreferences(
      preferredProvider: json['preferredProvider'] is String ? json['preferredProvider'] as String : null,
      models: models is Map
          ? <String, String>{
              for (final MapEntry<dynamic, dynamic> e in models.entries)
                if (e.key is String && e.value is String) e.key as String: e.value as String,
            }
          : const <String, String>{},
      fallbackEnabled: json['fallbackEnabled'] == true,
      fallbackProviders: providers is List ? providers.whereType<String>().toSet() : const <String>{},
      shareMemoryWithFallback: json['shareMemoryWithFallback'] == true,
      shareFilesWithFallback: json['shareFilesWithFallback'] == true,
    );
  }

  /// Null = the backend's default provider.
  final String? preferredProvider;

  /// Per-provider model choice (ids taken from the provider's live model list).
  final Map<String, String> models;
  final bool fallbackEnabled;
  final Set<String> fallbackProviders;
  final bool shareMemoryWithFallback;
  final bool shareFilesWithFallback;

  /// True when nothing was customised. Then no `routing` field is sent at all, so requests are
  /// byte-for-byte what earlier versions sent.
  bool get isDefault =>
      preferredProvider == null && models.isEmpty && !fallbackEnabled;

  RoutingPreferences copyWith({
    String? preferredProvider,
    bool clearPreferredProvider = false,
    Map<String, String>? models,
    bool? fallbackEnabled,
    Set<String>? fallbackProviders,
    bool? shareMemoryWithFallback,
    bool? shareFilesWithFallback,
  }) {
    return RoutingPreferences(
      preferredProvider:
          clearPreferredProvider ? null : (preferredProvider ?? this.preferredProvider),
      models: models ?? this.models,
      fallbackEnabled: fallbackEnabled ?? this.fallbackEnabled,
      fallbackProviders: fallbackProviders ?? this.fallbackProviders,
      shareMemoryWithFallback: shareMemoryWithFallback ?? this.shareMemoryWithFallback,
      shareFilesWithFallback: shareFilesWithFallback ?? this.shareFilesWithFallback,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'preferredProvider': preferredProvider,
        'models': models,
        'fallbackEnabled': fallbackEnabled,
        'fallbackProviders': fallbackProviders.toList()..sort(),
        'shareMemoryWithFallback': shareMemoryWithFallback,
        'shareFilesWithFallback': shareFilesWithFallback,
      };

  /// The `routing` object for POST /v1/chat, or null when nothing was customised.
  Map<String, Object?>? toRequestJson() {
    if (isDefault) return null;
    final Map<String, Object?> out = <String, Object?>{};
    if (preferredProvider != null) out['provider'] = preferredProvider;
    if (models.isNotEmpty) out['models'] = Map<String, String>.of(models);
    if (fallbackEnabled) {
      out['fallback'] = <String, Object?>{
        'enabled': true,
        'providers': fallbackProviders.toList()..sort(),
        'shareMemory': shareMemoryWithFallback,
        'shareAttachments': shareFilesWithFallback,
      };
    }
    return out;
  }
}

abstract class RoutingPreferencesStore {
  Future<RoutingPreferences> load();
  Future<void> save(RoutingPreferences value);
}

/// Stored in the app's private preferences. Contains no secrets (only provider ids and model ids).
class PrefsRoutingPreferencesStore implements RoutingPreferencesStore {
  static const String _key = 'routing_preferences_v1';

  @override
  Future<RoutingPreferences> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_key);
    if (raw == null) return const RoutingPreferences();
    try {
      return RoutingPreferences.fromJson(jsonDecode(raw));
    } on FormatException {
      return const RoutingPreferences();
    }
  }

  @override
  Future<void> save(RoutingPreferences value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(value.toJson()));
  }
}

class MemoryRoutingPreferencesStore implements RoutingPreferencesStore {
  MemoryRoutingPreferencesStore([this.value = const RoutingPreferences()]);

  RoutingPreferences value;

  @override
  Future<RoutingPreferences> load() async => value;

  @override
  Future<void> save(RoutingPreferences value) async => this.value = value;
}

class RoutingPreferencesController extends ValueNotifier<RoutingPreferences> {
  RoutingPreferencesController(this._store) : super(const RoutingPreferences());

  final RoutingPreferencesStore _store;

  Future<void> load() async {
    try {
      value = await _store.load();
    } on Exception {
      // Keep the safe defaults (fallback off).
    }
  }

  /// Applies the change immediately; returns false if it could not be stored on the device.
  Future<bool> update(RoutingPreferences next) async {
    value = next;
    try {
      await _store.save(next);
      return true;
    } on Exception {
      return false;
    }
  }
}
