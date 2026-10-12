import '../models/memory_item.dart';

/// Storage contract for personal memories and memory settings.
/// Everything stays on the phone; nothing here talks to the network.
abstract class MemoryRepository {
  /// Newest update first. Filters are optional.
  Future<List<MemoryItem>> list({MemoryStatus? status, MemoryCategory? category});

  Future<MemoryItem?> get(String id);

  /// Stores a new record. Throws a StorageException if the id already exists.
  Future<MemoryItem> insert(MemoryItem item);

  /// Replaces a record. Throws a StorageException if it no longer exists.
  Future<MemoryItem> update(MemoryItem item);

  /// Returns true when a record was removed.
  Future<bool> delete(String id);

  /// Deletes every memory (settings and per-chat switches are kept).
  Future<void> clearAll();

  /// The master switch. Memory is on until the user turns it off.
  Future<bool> isEnabled();
  Future<void> setEnabled(bool enabled);

  /// Per-conversation switch: true means memory is off for that chat.
  Future<bool> isConversationMemoryOff(String conversationId);
  Future<void> setConversationMemoryOff(String conversationId, bool off);

  /// Forgets every per-conversation switch.
  Future<void> clearConversationFlags();
}
