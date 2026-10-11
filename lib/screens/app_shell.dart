import 'package:flutter/material.dart';

import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../services/backend_client.dart';
import '../services/chat_service.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
import 'memory_screen.dart';
import 'settings_screen.dart';

/// Main scaffold with bottom navigation (Home, Chat, Memory, Settings).
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.themeMode,
    required this.onThemeModeChanged,
    required this.settings,
    required this.backend,
    this.chatService,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final SettingsController settings;
  final BackendClient backend;
  final ChatService? chatService;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late final ChatController _chat = ChatController(
    service: widget.chatService,
    engineChanges: widget.settings,
  );
  int _index = 0;

  @override
  void dispose() {
    _chat.dispose();
    super.dispose();
  }

  void _go(int index) => setState(() => _index = index);

  Widget _page() {
    return switch (_index) {
      0 => HomeScreen(chat: _chat, onNavigate: _go),
      1 => ChatScreen(chat: _chat),
      2 => const MemoryScreen(),
      _ => SettingsScreen(
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
          settings: widget.settings,
          backend: widget.backend,
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
