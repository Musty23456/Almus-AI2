import 'dart:async';

import 'package:flutter/material.dart';

import 'controllers/settings_controller.dart';
import 'data/conversation_repository.dart';
import 'data/memory_conversation_repository.dart';
import 'data/memory_repository.dart';
import 'data/volatile_memory_repository.dart';
import 'screens/app_shell.dart';
import 'screens/splash_screen.dart';
import 'services/backend_client.dart';
import 'services/chat_service.dart';
import 'services/routed_chat_service.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';
import 'widgets/app_background.dart';

/// Root widget of ALMUS AI.
class AlmusApp extends StatefulWidget {
  const AlmusApp({
    super.key,
    this.showSplash = true,
    this.chatService,
    this.settingsStore,
    this.backendClient,
    this.repository,
    this.memoryRepository,
    this.persistentHistory = true,
  });

  /// Whether to show the splash screen first (tests may skip it).
  final bool showSplash;

  /// Chat engine override. By default the app uses the backend when one is
  /// configured in Settings, and the demo engine otherwise.
  final ChatService? chatService;

  /// Where connection settings are stored (tests inject an in-memory store).
  final SettingsStore? settingsStore;

  /// HTTP client for the backend (tests inject a mock).
  final BackendClient? backendClient;

  /// Where conversations are stored. Defaults to an in-memory repository
  /// (main.dart passes the SQLite one).
  final ConversationRepository? repository;

  /// Where personal memories are stored (Phase 4). Defaults to an in-memory
  /// repository (main.dart passes the SQLite one).
  final MemoryRepository? memoryRepository;

  /// False when the database could not be opened, so the UI can warn the user.
  final bool persistentHistory;

  @override
  State<AlmusApp> createState() => _AlmusAppState();
}

class _AlmusAppState extends State<AlmusApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  late bool _splashDone = !widget.showSplash;

  late final SettingsController _settings =
      SettingsController(widget.settingsStore ?? PrefsSettingsStore());
  late final BackendClient _backend = widget.backendClient ?? BackendClient();
  late final ConversationRepository _repository =
      widget.repository ?? MemoryConversationRepository();
  late final MemoryRepository _memoryRepository =
      widget.memoryRepository ?? VolatileMemoryRepository();
  late final ChatService _chatService = widget.chatService ??
      RoutedChatService(settings: _settings, backend: _backend);

  @override
  void initState() {
    super.initState();
    unawaited(_settings.load());
  }

  @override
  void dispose() {
    _settings.dispose();
    if (widget.backendClient == null) {
      _backend.close();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ALMUS AI',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: _themeMode,
      builder: (BuildContext context, Widget? child) =>
          AppBackground(child: child ?? const SizedBox.shrink()),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: _splashDone
            ? AppShell(
                key: const ValueKey<String>('shell'),
                themeMode: _themeMode,
                onThemeModeChanged: (ThemeMode mode) =>
                    setState(() => _themeMode = mode),
                chatService: _chatService,
                settings: _settings,
                backend: _backend,
                repository: _repository,
                memoryRepository: _memoryRepository,
                persistentHistory: widget.persistentHistory,
              )
            : SplashScreen(
                key: const ValueKey<String>('splash'),
                onFinished: () {
                  if (mounted) {
                    setState(() => _splashDone = true);
                  }
                },
              ),
      ),
    );
  }
}
