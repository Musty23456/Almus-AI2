import 'dart:async';

import 'package:flutter/material.dart';

import 'ai/provider_status_controller.dart';
import 'ai/routing_preferences.dart';
import 'attachments/attachment_picker.dart';
import 'backup/backup_files.dart';
import 'backup/backup_store.dart';
import 'controllers/settings_controller.dart';
import 'voice/voice_consent.dart';
import 'data/conversation_repository.dart';
import 'data/memory_conversation_repository.dart';
import 'data/memory_repository.dart';
import 'data/volatile_memory_repository.dart';
import 'screens/app_shell.dart';
import 'screens/splash_screen.dart';
import 'security/app_lock_controller.dart';
import 'services/backend_client.dart';
import 'services/chat_service.dart';
import 'services/routed_chat_service.dart';
import 'services/settings_store.dart';
import 'theme/app_theme.dart';
import 'voice/speech_recognizer.dart';
import 'voice/speech_synthesizer.dart';
import 'voice/voice_settings_store.dart';
import 'widgets/app_background.dart';
import 'widgets/app_lock_gate.dart';

// Local AI (Phase 5)
import 'local_ai/local_ai_service.dart';

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
    this.speechRecognizer,
    this.speechSynthesizer,
    this.voiceSettingsStore,
    this.appLock,
    this.backupStore,
    this.backupFiles,
    this.backupInfoStore,
    this.attachmentPicker,
    this.voiceConsent,
    this.routingStore,
    this.localAI,
  });

  /// Phase 4: where the user's provider / fallback choices are stored (tests inject an in-memory store).
  final RoutingPreferencesStore? routingStore;

  /// Phase 3: chat attachments and the microphone explanation.
  final AttachmentPickerGateway? attachmentPicker;
  final VoiceConsentStore? voiceConsent;

  /// Phase 2: backup / restore. Null hides the Backup & Restore section (the
  /// database could not be opened, or a test did not provide one).
  final BackupStore? backupStore;
  final BackupFileGateway? backupFiles;
  final BackupInfoStore? backupInfoStore;

  /// Phase 7: the biometric app lock. main.dart passes the real one; tests
  /// pass one with a fake biometric service. Null means no lock at all, so
  /// the app behaves exactly as in Phase 6.
  final AppLockController? appLock;

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

  /// Phase 6 voice engines. main.dart passes the Android implementations;
  /// tests pass fakes. Voice features (microphone, read aloud) are available
  /// only when both are provided, so without them the app behaves exactly as
  /// in Phase 5.
  final SpeechRecognizerService? speechRecognizer;
  final SpeechSynthesizerService? speechSynthesizer;

  /// Where voice preferences are stored (tests inject an in-memory store).
  final VoiceSettingsStore? voiceSettingsStore;

  /// Phase 5: local deterministic tools service (optional). When provided,
  /// RoutedChatService may consult it before calling the backend.
  final LocalAIService? localAI;

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
  late final RoutingPreferencesController _routing =
      RoutingPreferencesController(widget.routingStore ?? PrefsRoutingPreferencesStore());
  late final ProviderStatusController _providerStatus =
      ProviderStatusController(backend: _backend, settings: _settings);
  late final ChatService _chatService = widget.chatService ??
      RoutedChatService(settings: _settings, backend: _backend, routing: _routing, localAI: widget.localAI);
  late final VoiceSettingsController _voiceSettings = VoiceSettingsController(
    widget.voiceSettingsStore ?? PrefsVoiceSettingsStore(),
  );

  bool get _voiceEnabled =>
      widget.speechRecognizer != null && widget.speechSynthesizer != null;

  @override
  void initState() {
    super.initState();
    unawaited(_settings.load());
    unawaited(_routing.load());
    if (_voiceEnabled) unawaited(_voiceSettings.load());
    unawaited(widget.appLock?.load());
  }

  @override
  void dispose() {
    _settings.dispose();
    _routing.dispose();
    _providerStatus.dispose();
    _voiceSettings.dispose();
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
      builder: (BuildContext context, Widget? child) {
        final Widget app = child ?? const SizedBox.shrink();
        final AppLockController? lock = widget.appLock;
        // The gate wraps the whole navigator, so the lock screen also covers
        // dialogs and any screen that is open.
        return AppBackground(
          child: lock == null
              ? app
              : AppLockGate(controller: lock, child: app),
        );
      },
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
                speechRecognizer: widget.speechRecognizer,
                speechSynthesizer: widget.speechSynthesizer,
                voiceSettings: _voiceEnabled ? _voiceSettings : null,
                appLock: widget.appLock,
                backupStore: widget.backupStore,
                backupFiles: widget.backupFiles,
                backupInfoStore: widget.backupInfoStore,
                attachmentPicker: widget.attachmentPicker,
                voiceConsent: widget.voiceConsent,
                routing: _routing,
                providerStatus: _providerStatus,
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
