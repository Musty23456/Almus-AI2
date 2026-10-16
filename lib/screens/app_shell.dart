import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/provider_status_controller.dart';
import '../ai/routing_preferences.dart';
import '../attachments/attachment_controller.dart';
import '../attachments/attachment_picker.dart';
import '../backup/backup_controller.dart';
import '../backup/backup_files.dart';
import '../backup/backup_store.dart';
import '../controllers/chat_controller.dart';
import '../controllers/history_controller.dart';
import '../controllers/memory_controller.dart';
import '../controllers/settings_controller.dart';
import '../data/conversation_repository.dart';
import '../data/memory_repository.dart';
import '../models/chat_message.dart';
import '../security/app_lock_controller.dart';
import '../services/backend_client.dart';
import '../services/chat_service.dart';
import '../voice/speech_recognizer.dart';
import '../voice/speech_synthesizer.dart';
import '../voice/voice_consent.dart';
import '../voice/voice_controller.dart';
import '../voice/voice_settings_store.dart';
import 'chat_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';

/// Main scaffold with bottom navigation (Home, Chat, History, Memory, Settings).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.settings,
    required this.backend,
    required this.repository,
    required this.memoryRepository,
    this.persistentHistory = true,
    this.chatService,
    this.speechRecognizer,
    this.speechSynthesizer,
    this.voiceSettings,
    this.appLock,
    this.backupStore,
    this.backupFiles,
    this.backupInfoStore,
    this.attachmentPicker,
    this.voiceConsent,
    this.routing,
    this.providerStatus,
  });

  /// Phase 4: provider choices and status (null hides the Settings section).
  final RoutingPreferencesController? routing;
  final ProviderStatusController? providerStatus;

  /// Phase 3: system pickers for chat attachments (null hides the attach button).
  final AttachmentPickerGateway? attachmentPicker;

  /// Phase 3: remembers that the microphone explanation was accepted.
  final VoiceConsentStore? voiceConsent;

  /// Phase 2 backup / restore (all three needed; null hides the section).
  final BackupStore? backupStore;
  final BackupFileGateway? backupFiles;
  final BackupInfoStore? backupInfoStore;

  /// Phase 7 biometric lock (null = no lock). Used to stop speech while the
  /// app is locked and to show the Security section in Settings.
  final AppLockController? appLock;

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final SettingsController settings;
  final BackendClient backend;
  final ConversationRepository repository;
  final MemoryRepository memoryRepository;
  final bool persistentHistory;
  final ChatService? chatService;

  /// Phase 6 voice. All three must be given to enable voice features.
  final SpeechRecognizerService? speechRecognizer;
  final SpeechSynthesizerService? speechSynthesizer;
  final VoiceSettingsController? voiceSettings;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late final MemoryController _memory =
      MemoryController(widget.memoryRepository);
  late final ChatController _chat = ChatController(
    service: widget.chatService,
    engineChanges: widget.settings,
    repository: widget.repository,
    persistent: widget.persistentHistory,
    memory: _memory,
    onAssistantReply: (ChatMessage m) {
      // Never read a private reply aloud while the lock screen is showing.
      if (widget.appLock?.privateContentVisible == false) return;
      _voice?.handleReply(m);
    },
    onConversationChanged: () => _voice?.stopAll(),
  );
  VoiceController? _voice;
  late final HistoryController _history = HistoryController(widget.repository);
  BackupController? _backup;
  AttachmentController? _attachments;
  int _index = 0;

  BackupController? _buildBackup() {
    final BackupStore? store = widget.backupStore;
    final BackupFileGateway? files = widget.backupFiles;
    final BackupInfoStore? info = widget.backupInfoStore;
    if (store == null || files == null || info == null) return null;
    return BackupController(
      store: store,
      conversations: widget.repository,
      files: files,
      infoStore: info,
      restoreBlockedReason: () => _chat.isBusy
          ? 'Wait for the assistant to finish its reply, then try again.'
          : null,
      onDataRestored: () async {
        await _chat.reloadAfterRestore();
        await _memory.load();
        await _history.refresh();
      },
    );
  }

  VoiceController? _buildVoice() {
    final SpeechRecognizerService? recognizer = widget.speechRecognizer;
    final SpeechSynthesizerService? synthesizer = widget.speechSynthesizer;
    final VoiceSettingsController? settings = widget.voiceSettings;
    if (recognizer == null || synthesizer == null || settings == null) {
      return null;
    }
    return VoiceController(
      recognizer: recognizer,
      synthesizer: synthesizer,
      settings: settings,
      avatar: _chat,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never keep listening or talking in the background. The permission
    // dialog only makes the app "inactive", which is deliberately ignored.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _voice?.interrupt();
    }
  }

  @override
  void initState() {
    super.initState();
    _voice = _buildVoice();
    _backup = _buildBackup();
    final AttachmentPickerGateway? picker = widget.attachmentPicker;
    _attachments = picker == null ? null : AttachmentController(picker: picker);
    WidgetsBinding.instance.addObserver(this);
    widget.appLock?.addListener(_onLockChanged);
    // Reopen the most recent saved conversation and load personal memory.
    unawaited(_chat.restoreLatest());
    unawaited(_memory.load());
  }

  /// As soon as the app locks, stop listening and talking.
  void _onLockChanged() {
    if (widget.appLock?.privateContentVisible == false) _voice?.interrupt();
  }

  @override
  void dispose() {
    widget.appLock?.removeListener(_onLockChanged);
    WidgetsBinding.instance.removeObserver(this);
    _voice?.dispose();
    _backup?.dispose();
    _attachments?.dispose();
    _history.dispose();
    _chat.dispose();
    _memory.dispose();
    super.dispose();
  }

  void _go(int index) => setState(() => _index = index);

  Widget _page() {
    return switch (_index) {
      0 => HomeScreen(chat: _chat, onNavigate: _go),
      1 => ChatScreen(
          chat: _chat,
          memory: _memory,
          voice: _voice,
          voiceSettings: widget.voiceSettings,
          attachments: _attachments,
          voiceConsent: widget.voiceConsent,
        ),
      2 => HistoryScreen(
          chat: _chat,
          history: _history,
          memory: _memory,
          onOpenChat: () => _go(1),
        ),
      3 => MemoryScreen(memory: _memory),
      _ => SettingsScreen(
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
          settings: widget.settings,
          backend: widget.backend,
          voiceSettings: widget.voiceSettings,
          voice: _voice,
          appLock: widget.appLock,
          backup: _backup,
          backupUnavailable: widget.backupStore == null && !widget.persistentHistory,
          routing: widget.routing,
          providers: widget.providerStatus,
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final bool keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: KeyedSubtree(
            key: ValueKey<int>(_index),
            child: _page(),
          ),
        ),
      ),
      bottomNavigationBar: keyboardOpen
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _go,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Chat',
                ),
                NavigationDestination(
                  icon: Icon(Icons.history_outlined),
                  selectedIcon: Icon(Icons.history),
                  label: 'History',
                ),
                NavigationDestination(
                  icon: Icon(Icons.psychology_outlined),
                  selectedIcon: Icon(Icons.psychology),
                  label: 'Memory',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
    );
  }
}
