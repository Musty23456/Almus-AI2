// Register LocalAIService and tools at app startup.

import 'package:flutter/material.dart';

import 'app.dart';
import 'avatar/avatar_profile.dart';
import 'attachments/attachment_picker.dart';
import 'backup/backup_files.dart';
import 'voice/voice_consent.dart';
import 'data/repository_factory.dart';
import 'security/app_lock_controller.dart';
import 'security/biometric_service.dart';
import 'security/lock_settings.dart';
import 'security/privacy_screen.dart';
import 'voice/speech_recognizer.dart';
import 'voice/speech_synthesizer.dart';

// Local AI
import 'local_ai/local_ai_service.dart';
import 'local_ai/tools/calculator.dart';
import 'local_ai/tools/unit_conversion.dart';
import 'local_ai/tools/text_tools.dart';
import 'local_ai/tools/statistics.dart';
import 'local_ai/tools/document_utils.dart';
import 'local_ai/tools/local_history.dart';
import 'local_ai/tools/memory_tools.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Optional local avatar tuning file. Missing/invalid -> built-in defaults.
  await AvatarProfile.preload();
  // Opens the local SQLite database; falls back to in-memory history if that fails.
  final RepositoryOpenResult result = await openDefaultRepository();
  // Phase 7: lock on by default. Android's own biometric prompt decides.
  final AppLockController appLock = AppLockController(
    service: LocalAuthBiometricService(),
    store: PrefsLockSettingsStore(),
    privacy: ChannelPrivacyScreen(),
  );

  // Create and register local tools (Phase 5)
  final LocalAIService localAI = LocalAIService();
  localAI.register(CalculatorTool());
  localAI.register(UnitConversionTool());
  localAI.register(TextTools());
  localAI.register(StatisticsTool());
  localAI.register(DocumentUtils());

  final database = result.database;
  if (database != null) {
    localAI.register(LocalHistoryTool(database));
    localAI.register(MemoryTools(database));
  }

  runApp(
    AlmusApp(
      appLock: appLock,
      repository: result.repository,
      memoryRepository: result.memory,
      persistentHistory: result.persistent,
      // Phase 2: backup / restore through the Android file picker.
      backupStore: result.backupStore,
      backupFiles: const FilePickerGateway(),
      backupInfoStore: const PrefsBackupInfoStore(),
      // Phase 3: attachments and the first-use microphone explanation.
      attachmentPicker: SystemAttachmentPicker(),
      voiceConsent: const PrefsVoiceConsentStore(),
      // Phase 6: Android speech engines. Nothing starts until the user taps
      // the microphone or a reply is read aloud.
      speechRecognizer: PlatformSpeechRecognizer(),
      speechSynthesizer: PlatformSpeechSynthesizer(),
      // Provide the local AI service to the app so RoutedChatService can use it.
      localAI: localAI,
    ),
  );
}
