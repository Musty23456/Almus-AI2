/// Formats a time as 24-hour HH:mm.
String formatTime(DateTime time) {
  final String hours = time.hour.toString().padLeft(2, '0');
  final String minutes = time.minute.toString().padLeft(2, '0');
  return '$hours:$minutes';
}
