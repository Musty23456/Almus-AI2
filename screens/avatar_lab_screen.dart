import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../avatar/avatar_profile.dart';
import '../models/robot_state.dart';
import '../widgets/glow_card.dart';
import '../widgets/robot_avatar.dart';
import '../widgets/state_pill.dart';

/// Developer-only screen for testing every avatar state.
///
/// It has its own state and never touches the chat, so it is safe to use at
/// any time. Unlock it in Settings by tapping the version row 7 times.
class AvatarLabScreen extends StatefulWidget {
  const AvatarLabScreen({super.key});

  /// Whether the developer tile is shown in Settings (per app session).
  static final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);

  @override
  State<AvatarLabScreen> createState() => _AvatarLabScreenState();
}

/// An asset bundle that always fails, to prove the avatar survives a
/// missing asset.
class _MissingBundle extends AssetBundle {
  @override
  Future<ByteData> load(String key) =>
      Future<ByteData>.error(FlutterError('Simulated missing asset: $key'));
}

class _AvatarLabScreenState extends State<AvatarLabScreen> {
  RobotState _state = RobotState.idle;
  bool _cycling = false;
  bool _manualMouth = false;
  double _mouth = 0.5;
  int _profileVersion = 0;
  int _fps = 0;
  int _lastFrames = AvatarRuntime.paintedFrames;
  Timer? _cycleTimer;
  Timer? _fpsTimer;
  final ValueNotifier<double?> _mouthLevel = ValueNotifier<double?>(null);

  @override
  void initState() {
    super.initState();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final int now = AvatarRuntime.paintedFrames;
      if (!mounted) return;
      setState(() {
        _fps = now - _lastFrames;
        _lastFrames = now;
      });
    });
  }

  @override
  void dispose() {
    _cycleTimer?.cancel();
    _fpsTimer?.cancel();
    _mouthLevel.dispose();
    super.dispose();
  }

  void _select(RobotState state) {
    setState(() => _state = state);
  }

  void _toggleCycle(bool on) {
    _cycleTimer?.cancel();
    setState(() => _cycling = on);
    if (!on) return;
    _cycleTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      if (!mounted) return;
      final int next = (_state.index + 1) % RobotState.values.length;
      setState(() => _state = RobotState.values[next]);
    });
  }

  void _setManualMouth(bool on) {
    setState(() => _manualMouth = on);
    _mouthLevel.value = on ? _mouth : null;
  }

  Future<void> _reloadProfile({required bool simulateMissing}) async {
    await AvatarProfile.preload(
      bundle: simulateMissing ? _MissingBundle() : null,
    );
    if (mounted) setState(() => _profileVersion++);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool reduceMotion = MediaQuery.of(context).disableAnimations;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Avatar Lab'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: <Widget>[
          Center(
            child: RobotAvatar(
              key: ValueKey<int>(_profileVersion),
              state: _state,
              size: 240,
              mouthLevel: _mouthLevel,
            ),
          ),
          const SizedBox(height: 4),
          Center(child: StatePill(state: _state)),
          const SizedBox(height: 6),
          Text(
            _state.description,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 18),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final RobotState s in RobotState.values)
                ChoiceChip(
                  key: Key('lab_state_${s.name}'),
                  label: Text(s.label),
                  selected: _state == s,
                  onSelected: (bool _) => _select(s),
                ),
            ],
          ),
          const SizedBox(height: 18),
          GlowCard(
            child: Column(
              children: <Widget>[
                SwitchListTile(
                  key: const Key('lab_cycle_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Auto-cycle all states'),
                  subtitle: const Text('Changes state every 2.5 seconds'),
                  value: _cycling,
                  onChanged: _toggleCycle,
                ),
                SwitchListTile(
                  key: const Key('lab_mouth_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Manual mouth level'),
                  subtitle: const Text(
                    'Simulates audio loudness while Talking',
                  ),
                  value: _manualMouth,
                  onChanged: _setManualMouth,
                ),
                if (_manualMouth)
                  Slider(
                    key: const Key('lab_mouth_slider'),
                    value: _mouth,
                    onChanged: (double v) {
                      setState(() => _mouth = v);
                      _mouthLevel.value = v;
                    },
                  ),
                ValueListenableBuilder<bool>(
                  valueListenable: AvatarRuntime.lowPower,
                  builder: (BuildContext context, bool low, Widget? _) {
                    return SwitchListTile(
                      key: const Key('lab_lowpower_switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Low-power mode'),
                      subtitle: const Text('20 fps, fewer glow rings'),
                      value: low,
                      onChanged: (bool v) => AvatarRuntime.lowPower.value = v,
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          GlowCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _stat('Painted frames / s', '$_fps'),
                _stat('Frame cap', '${AvatarProfile.current.maxFps} fps'),
                _stat(
                  'Profile source',
                  AvatarProfile.loadedFromAsset
                      ? 'assets/avatar/avatar_profile.json'
                      : 'built-in defaults',
                ),
                _stat('Reduce motion', reduceMotion ? 'on (static avatar)' : 'off'),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('lab_reload_profile'),
                        onPressed: () => _reloadProfile(simulateMissing: false),
                        child: const Text('Reload asset'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('lab_simulate_missing'),
                        onPressed: () => _reloadProfile(simulateMissing: true),
                        child: const Text('Simulate missing'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
