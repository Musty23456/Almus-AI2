/// User-editable connection settings for the Gemini backend.
class AppSettings {
  const AppSettings({this.backendUrl = '', this.accessToken = ''});

  /// Base URL of your deployed backend, e.g. https://almus-backend.onrender.com
  final String backendUrl;

  /// The APP_ACCESS_TOKEN you chose on the server (not the Gemini key).
  final String accessToken;

  /// True when a backend address is set, so chat uses real Gemini replies.
  bool get isConfigured => backendUrl.isNotEmpty;
}

/// Returns a cleaned https URL without trailing slashes, or null if invalid.
String? normalizeBackendUrl(String input) {
  String value = input.trim();
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  if (value.isEmpty) return null;
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.hasQuery || uri.fragment.isNotEmpty) return null;
  return value;
}
