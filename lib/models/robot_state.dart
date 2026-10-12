/// Visual states of the robot avatar (Phase 5 adds [happy]).
///
/// Application state -> avatar state mapping (see ChatController):
/// - waiting for input            -> [idle]
/// - voice input / typing active  -> [listening]
/// - AI request pending           -> [thinking]
/// - speech playback / reply      -> [talking]
/// - short celebration            -> [happy]
/// - failure                      -> [error]
enum RobotState {
  idle('Idle', 'Relaxed and ready when you are.'),
  listening('Listening', 'Eyes wide open, paying close attention.'),
  thinking('Thinking', 'Working through your request…'),
  talking('Talking', 'Responding to you.'),
  happy('Happy', 'Glad to help. Smiling.'),
  error('Error', 'Something went wrong. Please try again.');

  const RobotState(this.label, this.description);

  final String label;
  final String description;
}
