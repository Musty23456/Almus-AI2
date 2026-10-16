/// Provider information reported by the backend (Phase 4). The app never sees API keys;
/// it only sees what the backend chooses to report.

/// Health of a provider as measured by the backend.
///
/// [unknown] means "configured on the server but nothing has confirmed that it works yet".
/// The UI must not call a provider available unless it is [healthy] AND [ProviderInfo.verified].
enum ProviderState {
  unknown,
  healthy,
  degraded,
  rateLimited,
  quotaExhausted,
  unavailable,
  misconfigured,
  unconfigured,
}

ProviderState providerStateFromString(Object? value) {
  switch (value) {
    case 'healthy':
      return ProviderState.healthy;
    case 'degraded':
      return ProviderState.degraded;
    case 'rate_limited':
      return ProviderState.rateLimited;
    case 'quota_exhausted':
      return ProviderState.quotaExhausted;
    case 'unavailable':
      return ProviderState.unavailable;
    case 'misconfigured':
      return ProviderState.misconfigured;
    case 'unconfigured':
      return ProviderState.unconfigured;
    default:
      return ProviderState.unknown;
  }
}

class ProviderCapabilities {
  const ProviderCapabilities({
    this.text = true,
    this.extractedTextAttachments = false,
    this.images = false,
    this.maxInputTokens,
  });

  factory ProviderCapabilities.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const ProviderCapabilities();
    final Object? max = json['maxInputTokens'];
    return ProviderCapabilities(
      text: json['text'] != false,
      extractedTextAttachments: json['extractedTextAttachments'] == true,
      images: json['images'] == true,
      maxInputTokens: max is int ? max : null,
    );
  }

  final bool text;

  /// Can read text the phone extracted from documents (the files themselves are never uploaded).
  final bool extractedTextAttachments;

  /// Can analyse image pixels. No adapter supports this yet.
  final bool images;

  /// Largest request the backend will send to it, when known.
  final int? maxInputTokens;
}

/// One model offered by a provider (from the provider's own live model list).
class ProviderModel {
  const ProviderModel({required this.id, this.name, this.contextTokens, this.free});

  factory ProviderModel.fromJson(Map<String, dynamic> json) {
    final Object? context = json['contextTokens'];
    final Object? free = json['free'];
    final Object? name = json['name'];
    return ProviderModel(
      id: json['id'] as String,
      name: name is String ? name : null,
      contextTokens: context is int ? context : null,
      free: free is bool ? free : null,
    );
  }

  final String id;
  final String? name;
  final int? contextTokens;

  /// True/false when the provider publishes prices, null when unknown.
  final bool? free;
}

class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    required this.configured,
    required this.state,
    required this.verified,
    this.lastCheckedAt,
    this.retryAfterSeconds,
    this.lastErrorCategory,
    this.model,
    this.modelSource = 'none',
    this.capabilities = const ProviderCapabilities(),
    this.costPolicy = 'unknown',
    this.fallbackEligible = true,
    this.dataNote = '',
    this.limitsNote = '',
    this.isDefaultPrimary = false,
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) {
    final Object? checked = json['lastCheckedAt'];
    final Object? success = json['lastSuccessAt'];
    final Object? retry = json['retryAfterSeconds'];
    final Object? model = json['model'];
    return ProviderInfo(
      id: json['id'] as String,
      name: (json['name'] as String?) ?? (json['id'] as String),
      configured: json['configured'] == true,
      state: providerStateFromString(json['state']),
      verified: json['verified'] == true,
      lastCheckedAt: DateTime.tryParse(
        (checked is String ? checked : (success is String ? success : '')),
      ),
      retryAfterSeconds: retry is int ? retry : null,
      lastErrorCategory: json['lastErrorCategory'] as String?,
      model: model is String ? model : null,
      modelSource: (json['modelSource'] as String?) ?? 'none',
      capabilities: ProviderCapabilities.fromJson(json['capabilities']),
      costPolicy: (json['costPolicy'] as String?) ?? 'unknown',
      fallbackEligible: json['fallbackEligible'] != false,
      dataNote: (json['dataNote'] as String?) ?? '',
      limitsNote: (json['limitsNote'] as String?) ?? '',
      isDefaultPrimary: json['isDefaultPrimary'] == true,
    );
  }

  final String id;
  final String name;
  final bool configured;
  final ProviderState state;

  /// True only after a real health check or request succeeded.
  final bool verified;
  final DateTime? lastCheckedAt;
  final int? retryAfterSeconds;
  final String? lastErrorCategory;
  final String? model;

  /// `configured`, `auto` or `none`.
  final String modelSource;
  final ProviderCapabilities capabilities;

  /// `free_only`, `metered` or `unknown`: what the server operator declared.
  final String costPolicy;
  final bool fallbackEligible;
  final String dataNote;
  final String limitsNote;
  final bool isDefaultPrimary;

  /// Providers always process remotely; shown to the user as such.
  bool get isRemote => true;
}

class ProvidersSnapshot {
  const ProvidersSnapshot({
    required this.primaryDefault,
    required this.fallbackOrder,
    required this.providers,
    this.allowPaidFallback = false,
  });

  factory ProvidersSnapshot.fromJson(Map<String, dynamic> json) {
    final Object? list = json['providers'];
    final Object? order = json['fallbackOrder'];
    return ProvidersSnapshot(
      primaryDefault: json['primaryDefault'] as String?,
      allowPaidFallback: json['allowPaidFallback'] == true,
      fallbackOrder: order is List ? order.whereType<String>().toList() : const <String>[],
      providers: list is List
          ? list
              .whereType<Map<String, dynamic>>()
              .map(ProviderInfo.fromJson)
              .toList()
          : const <ProviderInfo>[],
    );
  }

  final String? primaryDefault;

  /// True when the server operator allows fallback to providers that may charge money.
  final bool allowPaidFallback;
  final List<String> fallbackOrder;
  final List<ProviderInfo> providers;

  ProviderInfo? byId(String id) {
    for (final ProviderInfo p in providers) {
      if (p.id == id) return p;
    }
    return null;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Honest, plain-language status. The word "working" appears only for a provider that a real call confirmed.
String describeProviderState(ProviderInfo p) {
  switch (p.state) {
    case ProviderState.unconfigured:
      return 'Not configured on your server';
    case ProviderState.healthy:
      if (!p.verified) return 'Not checked yet';
      final DateTime? t = p.lastCheckedAt?.toLocal();
      return t == null
          ? 'Working (confirmed)'
          : 'Working (confirmed ${_two(t.hour)}:${_two(t.minute)})';
    case ProviderState.degraded:
      return 'Not confirmed: recent problems';
    case ProviderState.rateLimited:
      final int? s = p.retryAfterSeconds;
      return s == null ? 'Rate limited' : 'Rate limited (retry in ${s}s)';
    case ProviderState.quotaExhausted:
      return 'Quota used up for now';
    case ProviderState.unavailable:
      return 'Temporarily unavailable';
    case ProviderState.misconfigured:
      return 'Needs attention on the server (key or model)';
    case ProviderState.unknown:
      return 'Not checked yet';
  }
}
