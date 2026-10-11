# ALMUS AI Personal Assistant — Phase 1

A personal AI assistant for Android, built with Flutter (Material 3).
**Phase 1 is the interface foundation only.** Chat replies are simulated and clearly labelled **DEMO MODE**. Nothing is connected to Gemini or any other AI service yet.

## Features (Phase 1)
- Polished splash screen and dark futuristic theme (blue / cyan / purple), optional light theme
- Animated humanoid robot avatar drawn in code (no assets needed) with states: idle, listening, thinking, talking, error
- Home, Chat, Memory and Settings sections with bottom navigation
- Chat UI: user/assistant bubbles, timestamps, input + send, clear chat, empty state, typing and error states, DEMO MODE banner
- Memory screen: honest placeholder (nothing is saved)
- Settings: theme preference, app info, about, privacy, version
- Widget tests and a GitHub Actions workflow that analyzes, tests and builds a release APK

## Project structure
```
lib/
  main.dart, app.dart
  models/        chat_message.dart, robot_state.dart
  controllers/   chat_controller.dart
  services/      chat_service.dart (interface), demo_chat_service.dart
  screens/       splash, app_shell, home, chat, memory, settings
  widgets/       robot_avatar.dart + shared UI widgets
  theme/         app_theme.dart
  utils/         formatters.dart, app_info.dart
test/            widget_test.dart
assets/          images/, animations/ (optional, unused in Phase 1)
.github/workflows/build-apk.yml
```
The `android/` folder is generated automatically by the workflow (`flutter create`) using the Flutter version it installs, so Gradle/Kotlin versions always match.

## Build the APK with GitHub Actions
1. Push to `main`, or open **Actions → Build Android APK → Run workflow**.
2. When the run is green, open it and download the **almus-ai-release-apk** artifact (a ZIP containing `app-release.apk`).
3. Extract it on your phone and open the APK. Allow "Install unknown apps" for your browser/Files app if Android asks.

The APK is signed with the debug key, which is fine for personal use. Do not publish it to the Play Store as is.

## Run locally (optional)
```
flutter create --platforms=android --org com.almus --project-name almus_ai .
flutter pub get
flutter analyze
flutter test
flutter run
```

## Preparing for Phase 2
Implement `ChatService` (see `lib/services/chat_service.dart`) with a Gemini-backed class and pass it to `ChatController`. Keep API keys out of the source code.

## Known limitations
- Replies are scripted; there is no real AI, voice, or persistent memory yet.
- Chat history and the theme choice are not saved when the app closes.
- Default Flutter launcher icon; debug-key signing.
- Keep `AppInfo.version` in `lib/utils/app_info.dart` in sync with `pubspec.yaml`.
# Almus-AI-
# Almus-AI-
# Almus-AI-
