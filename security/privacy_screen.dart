import 'package:flutter/services.dart';

/// Hides the app's content from screenshots, screen recording and the
/// Android recent-apps thumbnail (Android's FLAG_SECURE).
abstract class PrivacyScreen {
  Future<void> setSecure(bool secure);
}

/// Talks to the small piece of Kotlin that `tool/patch_android_biometric.py`
/// adds to MainActivity. If that code is missing (for example in tests or on
/// another platform) nothing happens and the app keeps working.
class ChannelPrivacyScreen implements PrivacyScreen {
  static const MethodChannel _channel = MethodChannel('almus.ai/privacy');

  @override
  Future<void> setSecure(bool secure) async {
    try {
      await _channel.invokeMethod<void>(
        'setSecure',
        <String, Object?>{'secure': secure},
      );
    } on MissingPluginException {
      // Not available here.
    } on PlatformException {
      // Ignore: privacy flag is best effort.
    }
  }
}
