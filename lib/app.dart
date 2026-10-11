import 'package:flutter/material.dart';

import 'screens/app_shell.dart';
import 'screens/splash_screen.dart';
import 'services/chat_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_background.dart';

/// Root widget of ALMUS AI.
class AlmusApp extends StatefulWidget {
  const AlmusApp({super.key, this.showSplash = true, this.chatService});

  /// Whether to show the splash screen first (tests may skip it).
  final bool showSplash;

  /// Chat engine override. Defaults to the Phase 1 demo engine.
  final ChatService? chatService;

  @override
  State<AlmusApp> createState() => _AlmusAppState();
}

class _AlmusAppState extends State<AlmusApp> {
  ThemeMode _themeMode = ThemeMode.dark;
  late bool _splashDone = !widget.showSplash;

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
                chatService: widget.chatService,
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
