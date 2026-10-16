import 'package:almus_ai/voice/speech_recognizer.dart';

/// Scriptable speech engine: the test plays the part of Android's speech
/// service and decides which events arrive and in what order.
class FakeSpeechEngine implements SpeechEngine {
  /// Results of successive initialize() calls (the last one repeats).
  List<bool> initResults = <bool>[true];
  bool permission = true;
  List<String> locales = <String>['en_US', 'ha_NG'];
  String? system;
  bool throwOnListen = false;

  int initCalls = 0;
  final List<bool> intentLookups = <bool>[];
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  String? lastLocale;
  bool listening = false;

  void Function(String message)? _onError;
  void Function(String status)? _onStatus;
  void Function(String words, bool isFinal)? _onResult;

  @override
  Future<bool> initialize({
    required void Function(String message) onError,
    required void Function(String status) onStatus,
    required bool intentLookup,
  }) async {
    _onError = onError;
    _onStatus = onStatus;
    intentLookups.add(intentLookup);
    final bool ok = initResults[initCalls < initResults.length ? initCalls : initResults.length - 1];
    initCalls++;
    return ok;
  }

  @override
  Future<bool> get hasPermission async => permission;

  @override
  Future<List<String>> localeIds() async => locales;

  @override
  Future<String?> systemLocaleId() async => system;

  @override
  bool get isListening => listening;

  @override
  Future<void> listen({
    required void Function(String words, bool isFinal) onResult,
    String? localeId,
    required Duration listenFor,
    required Duration pauseFor,
  }) async {
    if (throwOnListen) throw StateError('listen failed');
    listenCalls++;
    lastLocale = localeId;
    _onResult = onResult;
    listening = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    listening = false;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    listening = false;
  }

  // ---- drivers
  void status(String s) => _onStatus?.call(s);
  void result(String words, {bool isFinal = false}) => _onResult?.call(words, isFinal);
  void error(String message) => _onError?.call(message);
}
