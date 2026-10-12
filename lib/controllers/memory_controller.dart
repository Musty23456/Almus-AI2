import 'package:flutter/foundation.dart';

import '../data/memory_repository.dart';
import '../data/storage_exception.dart';
import '../models/memory_item.dart';
import '../services/memory_extractor.dart';
import '../services/memory_retrieval.dart';
import '../services/memory_text.dart';
import '../services/sensitive_filter.dart';
import '../utils/ids.dart';

/// What happened when the user tried to save or edit a memory.
enum MemorySaveStatus {
  saved,
  duplicate,
  blocked,
  needsConfirmation,
  empty,
  tooLong,
  failed,
}

class MemorySaveResult {
  const MemorySaveResult(this.status, this.message, {this.item});

  final MemorySaveStatus status;

  /// A user-safe explanation (empty when saved).
  final String message;

  /// The stored record when [status] is [MemorySaveStatus.saved].
  final MemoryItem? item;

  bool get isSaved => status == MemorySaveStatus.saved;
}

/// The memory notes chosen for one AI request.
class MemoryContext {
  const MemoryContext(this.text, this.used);

  /// The text added to the request, or null when nothing is sent.
  final String? text;

  /// The memories behind [text], most relevant first.
  final List<RetrievedMemory> used;

  static const MemoryContext none = MemoryContext(null, <RetrievedMemory>[]);
}

/// Manages the user's personal memories: add, edit, delete, confirm,
/// suggestions, retrieval for AI requests, and the on/off switches.
class MemoryController extends ChangeNotifier {
  MemoryController(this._repository, {DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final MemoryRepository _repository;
  final DateTime Function() _now;

  List<MemoryItem> _items = const <MemoryItem>[];
  bool _enabled = true;
  bool _loaded = false;
  bool _loading = false;
  bool _disposed = false;
  String? _error;

  List<MemoryItem> get items => _items;

  /// Memories the user approved (these are the only ones ever sent to the AI).
  List<MemoryItem> get confirmed =>
      _items.where((MemoryItem m) => m.isConfirmed).toList();

  /// Memories Almus proposed that wait for a decision.
  List<MemoryItem> get suggestions =>
      _items.where((MemoryItem m) => m.isSuggested).toList();

  bool get enabled => _enabled;
  bool get isLoading => _loading;
  bool get isLoaded => _loaded;

  /// A user-safe message when memory could not be loaded or changed.
  String? get error => _error;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() async {
    _loading = true;
    _error = null;
    _notify();
    try {
      _enabled = await _repository.isEnabled();
      _items = await _repository.list();
      _loaded = true;
    } on StorageException catch (e) {
      _error = e.message;
    }
    _loading = false;
    _notify();
  }

  /// Makes sure the stored memories are known before checking for duplicates.
  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _reload() async {
    try {
      _items = await _repository.list();
      _error = null;
    } on StorageException catch (e) {
      _error = e.message;
    }
    _notify();
  }

  Future<bool> setEnabled(bool value) async {
    try {
      await _repository.setEnabled(value);
      _enabled = value;
      _error = null;
      _notify();
      return true;
    } on StorageException catch (e) {
      _error = e.message;
      _notify();
      return false;
    }
  }

  // ----------------------------------------------------------- validation

  MemorySaveResult? _validate(
    String text, {
    required bool allowSensitive,
    String? ignoreId,
  }) {
    if (text.isEmpty) {
      return const MemorySaveResult(
        MemorySaveStatus.empty,
        'Write something to remember first.',
      );
    }
    if (text.length > kMaxMemoryChars) {
      return const MemorySaveResult(
        MemorySaveStatus.tooLong,
        'That is too long. Keep a memory under $kMaxMemoryChars characters.',
      );
    }
    final SensitivityResult sensitivity = checkSensitivity(text);
    if (sensitivity.level == Sensitivity.blocked) {
      return MemorySaveResult(
        MemorySaveStatus.blocked,
        'Almus never stores ${sensitivity.reason}. Remove it and try again.',
      );
    }
    if (sensitivity.level == Sensitivity.sensitive && !allowSensitive) {
      return MemorySaveResult(
        MemorySaveStatus.needsConfirmation,
        'This looks like sensitive information (${sensitivity.reason}). It would be kept on this phone and sent to the AI when it seems relevant. Save it anyway?',
      );
    }
    if (findDuplicateMemory(text, _items, ignoreId: ignoreId) != null) {
      return const MemorySaveResult(
        MemorySaveStatus.duplicate,
        'You already have a very similar memory.',
      );
    }
    return null;
  }

  MemorySaveResult _failed(StorageException e) => MemorySaveResult(
        MemorySaveStatus.failed,
        'Could not save (${e.message})',
      );

  // -------------------------------------------------------------- changes

  /// Saves a memory the user wrote or approved. Sensitive text needs
  /// [allowSensitive] (the UI asks first); secrets are always refused.
  Future<MemorySaveResult> add({
    required MemoryCategory category,
    required String text,
    String? sourceConversationId,
    bool allowSensitive = false,
  }) async {
    await _ensureLoaded();
    final String clean = cleanMemoryText(text);
    final MemorySaveResult? problem =
        _validate(clean, allowSensitive: allowSensitive);
    if (problem != null) return problem;
    final DateTime time = _now();
    final MemoryItem item = MemoryItem(
      id: newId('mem'),
      category: category,
      text: clean,
      createdAt: time,
      updatedAt: time,
      sourceConversationId: sourceConversationId,
    );
    try {
      await _repository.insert(item);
    } on StorageException catch (e) {
      return _failed(e);
    }
    await _reload();
    return MemorySaveResult(MemorySaveStatus.saved, '', item: item);
  }

  /// Edits a memory's text and/or category. The status is unchanged.
  Future<MemorySaveResult> edit(
    String id, {
    MemoryCategory? category,
    String? text,
    bool allowSensitive = false,
  }) async {
    await _ensureLoaded();
    final MemoryItem? current = _find(id);
    if (current == null) {
      return const MemorySaveResult(
        MemorySaveStatus.failed,
        'That memory no longer exists.',
      );
    }
    final String clean = cleanMemoryText(text ?? current.text);
    final MemorySaveResult? problem =
        _validate(clean, allowSensitive: allowSensitive, ignoreId: id);
    if (problem != null) return problem;
    final MemoryItem updated = current.copyWith(
      category: category,
      text: clean,
      updatedAt: _now(),
    );
    try {
      await _repository.update(updated);
    } on StorageException catch (e) {
      return _failed(e);
    }
    await _reload();
    return MemorySaveResult(MemorySaveStatus.saved, '', item: updated);
  }

  /// Approves a suggestion so it can be used in AI requests.
  Future<MemorySaveResult> confirm(String id, {bool allowSensitive = false}) async {
    await _ensureLoaded();
    final MemoryItem? current = _find(id);
    if (current == null) {
      return const MemorySaveResult(
        MemorySaveStatus.failed,
        'That suggestion no longer exists.',
      );
    }
    final SensitivityResult sensitivity = checkSensitivity(current.text);
    if (sensitivity.level == Sensitivity.blocked) {
      return MemorySaveResult(
        MemorySaveStatus.blocked,
        'Almus never stores ${sensitivity.reason}.',
      );
    }
    if (sensitivity.level == Sensitivity.sensitive && !allowSensitive) {
      return MemorySaveResult(
        MemorySaveStatus.needsConfirmation,
        'This looks like sensitive information (${sensitivity.reason}). It would be kept on this phone and sent to the AI when it seems relevant. Save it anyway?',
      );
    }
    final MemoryItem updated =
        current.copyWith(status: MemoryStatus.confirmed, updatedAt: _now());
    try {
      await _repository.update(updated);
    } on StorageException catch (e) {
      return _failed(e);
    }
    await _reload();
    return MemorySaveResult(MemorySaveStatus.saved, '', item: updated);
  }

  /// Declines a suggestion. It is deleted.
  Future<bool> reject(String id) => delete(id);

  Future<bool> delete(String id) async {
    try {
      await _repository.delete(id);
    } on StorageException catch (e) {
      _error = e.message;
      _notify();
      return false;
    }
    await _reload();
    return true;
  }

  /// Deletes every memory and suggestion.
  Future<bool> clearAll() async {
    try {
      await _repository.clearAll();
    } on StorageException catch (e) {
      _error = e.message;
      _notify();
      return false;
    }
    await _reload();
    return true;
  }

  MemoryItem? _find(String id) {
    for (final MemoryItem item in _items) {
      if (item.id == id) return item;
    }
    return null;
  }

  // ---------------------------------------------------------- suggestions

  /// Proposes memories from something the user wrote. Nothing is saved as a
  /// confirmed memory; the user decides. Returns the new suggestions.
  /// Never throws, and does nothing while memory is off.
  Future<List<MemoryItem>> suggestFrom(
    String message, {
    String? conversationId,
  }) async {
    final List<MemoryItem> created = <MemoryItem>[];
    try {
      // Load first so a saved "memory off" choice is known before anything is proposed.
      if (!_loaded) await load();
      if (!_enabled) return created;
      for (final MemorySuggestion s in extractMemorySuggestions(message)) {
        if (findDuplicateMemory(s.text, _items) != null) continue;
        final DateTime time = _now();
        final MemoryItem item = MemoryItem(
          id: newId('mem'),
          category: s.category,
          text: s.text,
          createdAt: time,
          updatedAt: time,
          sourceConversationId: conversationId,
          status: MemoryStatus.suggested,
        );
        await _repository.insert(item);
        _items = <MemoryItem>[item, ..._items];
        created.add(item);
      }
    } on StorageException {
      // Suggestions are optional; ignore storage problems.
    }
    if (created.isNotEmpty) _notify();
    return created;
  }

  // ------------------------------------------------------------ retrieval

  /// Picks the memories to include with an AI request.
  ///
  /// Returns [MemoryContext.none] when memory is off (globally or for this
  /// chat) or nothing is relevant. Only confirmed memories are considered.
  Future<MemoryContext> contextFor(
    String message, {
    String? previousUserText,
    bool chatMemoryOff = false,
  }) async {
    if (!_enabled || chatMemoryOff) return MemoryContext.none;
    try {
      if (!_loaded) await load();
    } on Exception {
      return MemoryContext.none;
    }
    if (!_enabled) return MemoryContext.none;
    final List<RetrievedMemory> picked = retrieveMemories(
      query: message,
      candidates: _items,
      previousUserText: previousUserText,
    );
    if (picked.isEmpty) return MemoryContext.none;
    final String? text = buildMemoryContext(picked);
    if (text == null) return MemoryContext.none;
    return MemoryContext(text, picked);
  }

  // ------------------------------------------------------- per-chat switch

  Future<bool> isConversationOff(String conversationId) async {
    try {
      return await _repository.isConversationMemoryOff(conversationId);
    } on StorageException {
      return false;
    }
  }

  Future<bool> setConversationOff(String conversationId, bool off) async {
    try {
      await _repository.setConversationMemoryOff(conversationId, off);
      return true;
    } on StorageException {
      return false;
    }
  }

  Future<void> forgetConversationFlags() async {
    try {
      await _repository.clearConversationFlags();
    } on StorageException {
      // Best effort.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
