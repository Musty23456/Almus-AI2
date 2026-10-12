import 'package:flutter/foundation.dart';

import '../data/conversation_repository.dart';
import '../data/storage_exception.dart';
import '../models/conversation.dart';

/// List/search state for the saved-conversation list on the Memory screen.
class HistoryController extends ChangeNotifier {
  HistoryController(this._repository);

  final ConversationRepository _repository;

  List<Conversation> _items = const <Conversation>[];
  String _query = '';
  bool _loading = false;
  String? _error;
  bool _disposed = false;
  int _token = 0;

  List<Conversation> get items => _items;
  String get query => _query;
  bool get isLoading => _loading;
  String? get error => _error;

  /// Reloads the list using the current search text.
  Future<void> refresh() async {
    final int token = ++_token;
    _loading = true;
    _error = null;
    _notify();
    try {
      final List<Conversation> result =
          await _repository.listConversations(query: _query);
      if (token != _token) return;
      _items = result;
    } on StorageException catch (e) {
      if (token != _token) return;
      _items = const <Conversation>[];
      _error = e.message;
    }
    _loading = false;
    _notify();
  }

  Future<void> setQuery(String query) {
    _query = query.trim();
    return refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
