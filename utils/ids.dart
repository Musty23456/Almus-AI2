import 'dart:math';

final Random _random = Random();
int _counter = 0;

/// Creates a unique id such as `c1x2y3-1-ab12`. Safe to generate on-device.
String newId(String prefix) {
  _counter = (_counter + 1) & 0xFFFF;
  final String time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final String random = _random.nextInt(1 << 30).toRadixString(36);
  return '$prefix$time-${_counter.toRadixString(36)}-$random';
}
