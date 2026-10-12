import '../models/memory_item.dart';
import 'memory_repository.dart';
import 'storage_exception.dart';

/// Keeps memories in RAM only. Used by tests and as a fallback when the
/// database cannot be opened (nothing survives a restart).
class VolatileMemoryRepository implements MemoryRepository {
  final Map<String, MemoryItem> _items = <String, MemoryItem>{};
  final Set<String> _off = <String>{};
  bool _enabled = true;

  @override
  Future<List<MemoryItem>> list({
    MemoryStatus? status,
    MemoryCategory? category,
  }) async {
    final List<MemoryItem> result = _items.values.where((MemoryItem m) {
      if (status != null && m.status != status) return false;
      if (category != null && m.category != category) return false;
      return true;
    }).toList()
      ..sort((MemoryItem a, MemoryItem b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  @override
  Future<MemoryItem?> get(String id) async => _items[id];

  @override
  Future<MemoryItem> insert(MemoryItem item) async {
    if (_items.containsKey(item.id)) {
      throw const StorageException('That memory already exists.');
    }
    _items[item.id] = item;
    return item;
  }

  @override
  Future<MemoryItem> update(MemoryItem item) async {
    if (!_items.containsKey(item.id)) {
      throw const StorageException('That memory no longer exists.');
    }
    _items[item.id] = item;
    return item;
  }

  @override
  Future<bool> delete(String id) async => _items.remove(id) != null;

  @override
  Future<void> clearAll() async => _items.clear();

  @override
  Future<bool> isEnabled() async => _enabled;

  @override
  Future<void> setEnabled(bool enabled) async => _enabled = enabled;

  @override
  Future<bool> isConversationMemoryOff(String conversationId) async =>
      _off.contains(conversationId);

  @override
  Future<void> setConversationMemoryOff(String conversationId, bool off) async {
    if (off) {
      _off.add(conversationId);
    } else {
      _off.remove(conversationId);
    }
  }

  @override
  Future<void> clearConversationFlags() async => _off.clear();
}
