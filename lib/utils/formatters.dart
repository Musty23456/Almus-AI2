/// Formats a time as 24-hour HH:mm.
String formatTime(DateTime time) {
  final String hours = time.hour.toString().padLeft(2, '0');
  final String minutes = time.minute.toString().padLeft(2, '0');
  return '$hours:$minutes';
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Today 14:05", "Yesterday 09:30", "12 Oct" or "12 Oct 2025".
String formatRelativeDate(DateTime time, {DateTime? now}) {
  final DateTime current = now ?? DateTime.now();
  final DateTime today = DateTime.utc(current.year, current.month, current.day);
  final DateTime day = DateTime.utc(time.year, time.month, time.day);
  final int diff = today.difference(day).inDays;
  if (diff == 0) return 'Today ${formatTime(time)}';
  if (diff == 1) return 'Yesterday ${formatTime(time)}';
  final String base = '${time.day} ${_months[time.month - 1]}';
  return time.year == current.year ? base : '$base ${time.year}';
}
