import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/app_settings.dart';
import 'chat_service.dart';

/// Result of a successful connection test.
class ConnectionInfo {
  const ConnectionInfo({required this.model, this.fallbackModel});

  final String model;
  final String? fallbackModel;
}

/// Talks to the Almus backend. The Gemini API key never reaches the app;
/// only the backend URL and your access token are used here.
class BackendClient {
  BackendClient({http.Client? client, this.timeout = const Duration(seconds: 60)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  void close() => _client.close();

  /// Sends the conversation and returns the assistant's reply.
  Future<String> chat(
    AppSettings settings,
    List<Map<String, String>> messages,
  ) async {
    final Map<String, dynamic> json = await _send(
      settings,
      'POST',
      '/v1/chat',
      body: <String, dynamic>{'messages': messages},
    );
    final Object? reply = json['reply'];
    if (reply is! String || reply.trim().isEmpty) {
      throw const ChatServiceException(
        'The backend returned an empty or invalid reply.',
        code: 'invalid_response',
      );
    }
    return reply.trim();
  }

  /// Checks the backend address, access token and server-side Gemini setup
  /// without sending a chat message.
  Future<ConnectionInfo> checkConnection(AppSettings settings) async {
    final Map<String, dynamic> health =
        await _send(settings, 'GET', '/health', auth: false);
    if (health['geminiConfigured'] != true) {
      throw const ChatServiceException(
        'The backend is reachable, but GEMINI_API_KEY is not set on the server.',
        code: 'server_not_configured',
      );
    }
    final Map<String, dynamic> info = await _send(settings, 'GET', '/v1/models');
    final Object? model = info['configuredModel'];
    final Object? fallback = info['fallbackModel'];
    return ConnectionInfo(
      model: model is String ? model : 'unknown',
      fallbackModel: fallback is String ? fallback : null,
    );
  }

  Future<Map<String, dynamic>> _send(
    AppSettings settings,
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    final Uri uri;
    try {
      uri = Uri.parse('${settings.backendUrl}$path');
    } on FormatException {
      throw const ChatServiceException(
        'The backend address is not valid. Check it in Settings.',
        code: 'bad_url',
      );
    }

    final Map<String, String> headers = <String, String>{
      'accept': 'application/json',
    };
    if (body != null) headers['content-type'] = 'application/json';
    if (auth && settings.accessToken.isNotEmpty) {
      headers['authorization'] = 'Bearer ${settings.accessToken}';
    }

    final http.Response response;
    try {
      final Future<http.Response> request = method == 'POST'
          ? _client.post(uri, headers: headers, body: jsonEncode(body))
          : _client.get(uri, headers: headers);
      response = await request.timeout(timeout);
    } on TimeoutException {
      throw const ChatServiceException(
        'The backend took too long to answer. If it runs on free hosting it may be waking up, so try again in a minute.',
        code: 'timeout',
      );
    } on http.ClientException {
      throw const ChatServiceException(
        'Could not reach the backend. Check your internet connection and the backend address in Settings.',
        code: 'network',
      );
    } on Exception {
      throw const ChatServiceException(
        'Could not reach the backend. Check your internet connection and the backend address in Settings.',
        code: 'network',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
    } on FormatException {
      decoded = null;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded is Map<String, dynamic>) return decoded;
      throw const ChatServiceException(
        'The backend sent a response the app could not understand.',
        code: 'invalid_response',
      );
    }
    throw _errorFor(response.statusCode, decoded);
  }

  ChatServiceException _errorFor(int status, Object? decoded) {
    String? message;
    String? code;
    if (decoded is Map<String, dynamic>) {
      final Object? error = decoded['error'];
      if (error is Map<String, dynamic>) {
        final Object? m = error['message'];
        final Object? c = error['code'];
        if (m is String && m.isNotEmpty) message = m;
        if (c is String && c.isNotEmpty) code = c;
      }
    }

    if (status == 401) {
      return const ChatServiceException(
        'The backend rejected the access token. Check the token in Settings.',
        code: 'unauthorized',
      );
    }
    if (status == 404 && code == null) {
      return const ChatServiceException(
        'Backend address not found. Check the URL in Settings.',
        code: 'not_found',
      );
    }
    if (message != null) {
      return ChatServiceException(message, code: code ?? 'error');
    }
    if (status == 429) {
      return const ChatServiceException(
        'Too many requests. Please wait a moment and try again.',
        code: 'rate_limited',
      );
    }
    if (status >= 500) {
      return ChatServiceException(
        'The backend had a problem (HTTP $status). If it runs on free hosting it may be waking up, so try again in a minute.',
        code: 'server_error',
      );
    }
    return ChatServiceException(
      'Unexpected response from the backend (HTTP $status).',
      code: 'error',
    );
  }
}
