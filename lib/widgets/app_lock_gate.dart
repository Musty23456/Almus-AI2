import 'package:flutter/material.dart';

import '../screens/lock_screen.dart';
import '../security/app_lock_controller.dart';

/// Sits above the whole app (including dialogs and other routes).
///
/// * While locked, the real app is hidden, cannot be tapped and is excluded
///   from accessibility; the opaque lock screen covers it.
/// * Before the first unlock the real app is not even built, so private
///   screens cannot flash before the lock appears.
/// * It forwards Android lifecycle events to the controller (auto-lock).
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});

  final AppLockController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _childBuilt = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(AppLockGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// A text field hidden behind the lock must not keep the keyboard open.
  void _onChange() {
    if (!widget.controller.privateContentVisible) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.onLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) {
        final bool visible = widget.controller.privateContentVisible;
        if (visible) _childBuilt = true;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_childBuilt)
              Offstage(
                key: const Key('app_lock_content'),
                offstage: !visible,
                child: TickerMode(enabled: visible, child: widget.child),
              ),
            if (!visible)
              Positioned.fill(
                key: const Key('app_lock_screen'),
                child: LockScreen(controller: widget.controller),
              ),
          ],
        );
      },
    );
  }
}
