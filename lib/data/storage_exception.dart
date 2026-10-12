/// A local storage problem. [message] is safe to show to the user and never
/// contains message text or credentials.
class StorageException implements Exception {
  const StorageException(this.message);

  final String message;

  @override
  String toString() => 'StorageException: $message';
}
