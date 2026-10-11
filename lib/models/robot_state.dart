/// Visual states of the robot avatar.
enum RobotState {
  idle('Idle', 'Relaxed and ready when you are.'),
  listening('Listening', 'Eyes wide open, paying close attention.'),
  thinking('Thinking', 'Working through your request…'),
  talking('Talking', 'Responding to you.'),
  error('Error', 'Something went wrong. Please try again.');

  const RobotState(this.label, this.description);

  final String label;
  final String description;
}
