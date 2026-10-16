import 'package:flutter/foundation.dart';

import '../controllers/settings_controller.dart';
import '../services/backend_client.dart';
import '../services/chat_service.dart';
import 'provider_info.dart';

/// Holds what the backend reports about its AI providers (Phase 4).
///
/// [refresh] only reads known state. Only [checkAll] / [checkOne] make the backend contact the providers,
/// and only after one of those succeeds can a provider be shown as working.
class ProviderStatusController extends ChangeNotifier {
  ProviderStatusController({required this.backend, required this.settings});

  final BackendClient backend;
  final SettingsController settings;

  ProvidersSnapshot? _snapshot;
  bool _loading = false;
  bool _checking = false;
  String? _error;
  bool _disposed = false;
  final Map<String, List<ProviderModel>> _models = <String, List<ProviderModel>>{};
  final Set<String> _loadingModels = <String>{};
  final Map<String, String> _modelErrors = <String, String>{};

  ProvidersSnapshot? get snapshot => _snapshot;
  bool get isLoading => _loading;
  bool get isChecking => _checking;
  String? get error => _error;
  List<ProviderModel>? modelsFor(String id) => _models[id];
  bool isLoadingModels(String id) => _loadingModels.contains(id);
  String? modelError(String id) => _modelErrors[id];

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _messageFor(Object e) =>
      e is ChatServiceException ? e.message : 'Could not reach the backend. Please try again.';

  /// Reads the backend's current view of its providers (no provider is contacted).
  Future<void> refresh() async {
    if (!settings.value.isConfigured) {
      _snapshot = null;
      _error = null;
      _notify();
      return;
    }
    _loading = true;
    _error = null;
    _notify();
    try {
      _snapshot = await backend.listProviders(settings.value);
    } on Exception catch (e) {
      _error = _messageFor(e);
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Asks the backend to really contact every configured provider.
  Future<void> checkAll() => _check(null);

  /// Really contacts one provider.
  Future<void> checkOne(String providerId) => _check(providerId);

  Future<void> _check(String? providerId) async {
    if (!settings.value.isConfigured || _checking) return;
    _checking = true;
    _error = null;
    _notify();
    try {
      final ProvidersSnapshot checked =
          await backend.checkProviders(settings.value, providerId: providerId);
      // Merge by id: a check may return fewer providers than the earlier list (for example unconfigured ones).
      final ProvidersSnapshot? old = _snapshot;
      _snapshot = old == null
          ? checked
          : ProvidersSnapshot(
              primaryDefault: old.primaryDefault,
              allowPaidFallback: old.allowPaidFallback,
              fallbackOrder: old.fallbackOrder,
              providers: <ProviderInfo>[
                for (final ProviderInfo p in old.providers) checked.byId(p.id) ?? p,
              ],
            );
    } on Exception catch (e) {
      _error = _messageFor(e);
    } finally {
      _checking = false;
      _notify();
    }
  }

  /// Loads the provider's live model list (cached after the first success).
  Future<List<ProviderModel>> loadModels(String providerId, {bool force = false}) async {
    final List<ProviderModel>? cached = _models[providerId];
    if (cached != null && !force) return cached;
    _loadingModels.add(providerId);
    _modelErrors.remove(providerId);
    _notify();
    try {
      final List<ProviderModel> list =
          await backend.listProviderModels(settings.value, providerId);
      _models[providerId] = list;
      return list;
    } on Exception catch (e) {
      _modelErrors[providerId] = _messageFor(e);
      return const <ProviderModel>[];
    } finally {
      _loadingModels.remove(providerId);
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
