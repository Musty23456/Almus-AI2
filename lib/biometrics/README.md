```dart
name: lib/biometrics/face_recognition_service.dart
```

This file contains the implementation of the on-device TFLite inference service used by the Phase 6 face-recognition feature. It wires `tflite_flutter` and the MobileFaceNet + anti-spoofing models and exposes a simple API for embedding generation, liveness scoring, and matching.

Important: the full Dart source was added to the repo in subsequent commits on this branch.
