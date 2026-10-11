# ALMUS AI Personal Assistant — Phase 2

A personal AI assistant for Android, built with Flutter (Material 3).

**Phase 2** adds real Gemini conversations through a backend that you deploy yourself (see the separate `almus-backend` project). The app never contains your Gemini API key. In **Settings → Gemini connection** you enter your backend URL and an access token. With no backend URL the app stays in clearly labelled **DEMO MODE** (scripted replies).

## Features
- Polished splash screen and dark futuristic theme (blue / cyan / purple), optional light theme
- Animated humanoid robot avatar drawn in code (no assets needed) with states: idle, listening, thinking, talking, error
- Home, Chat, Memory and Settings sections with bottom navigation
- Chat UI: bubbles, timestamps, send, clear chat, empty/typing/error states, DEMO MODE or LIVE MODE banner
- Real Gemini replies via your backend with conversation context (last 20 messages / 12,000 characters), robot THINKING while waiting then TALKING/IDLE, and no duplicate submissions
- Friendly messages for no internet, timeouts, rate limits / quota, wrong token, and backend errors
- Settings: backend URL + access token (stored in app-private storage), Test connection button
- Memory screen: honest placeholder (nothing is saved)
- Settings: theme preference, app info, about, privacy, version
- Widget tests and a GitHub Actions workflow that analyzes, tests and builds a release APK

## Project structure
```
lib/
  main.dart, app.dart
  models/        chat_message.dart, robot_state.dart, app_settings.dart
  controllers/   chat_controller.dart, settings_controller.dart
  services/      chat_service.dart, demo_chat_service.dart, backend_client.dart,
                 routed_chat_service.dart, settings_store.dart
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

## Connecting to Gemini
1. Deploy the backend (`almus-backend`, see its README) and set `GEMINI_API_KEY` and `APP_ACCESS_TOKEN` in the hosting dashboard.
2. In the app open **Settings → Gemini connection**, enter the https backend URL and the same access token, tap **Test connection**, then **Save**.
3. Chat switches to LIVE MODE. Clear the URL to return to DEMO MODE.

The model is chosen on the backend (`GEMINI_MODEL`), so changing it never needs a new APK. The release APK includes the INTERNET permission (added by the workflow).

## Known limitations
- No voice or persistent memory yet. Replies are not streamed; they appear when complete.
- Chat history and the theme choice are not saved when the app closes (the backend URL and token are).
- The access token is stored unencrypted in app-private storage.
- Live replies need a deployed backend and a Gemini key whose free-tier quota and policy are set by Google.
- Default Flutter launcher icon; debug-key signing.
- Keep `AppInfo.version` in `lib/utils/app_info.dart` in sync with `pubspec.yaml`.
