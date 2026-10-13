import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Phase 9: private, on-device face detection and enrollment prototype.
///
/// IMPORTANT: ML Kit Face Detection detects face geometry; it does not identify
/// a person. This screen deliberately does not unlock the app. The real app
/// lock remains Android's LocalAuthentication/BiometricPrompt until a reviewed
/// face-embedding recognition model and liveness checks are integrated.
class FaceEnrollmentScreen extends StatefulWidget {
  const FaceEnrollmentScreen({super.key});

  @override
  State<FaceEnrollmentScreen> createState() => _FaceEnrollmentScreenState();
}

class _FaceEnrollmentScreenState extends State<FaceEnrollmentScreen> {
  static const String _savedPathKey = 'phase9_face_enrollment_path';
  final ImagePicker _picker = ImagePicker();
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableLandmarks: true,
      enableContours: true,
      enableClassification: true,
      performanceMode: FaceDetectorMode.accurate,
      minFaceSize: 0.12,
    ),
  );

  String? _savedPath;
  String _status = 'No face sample enrolled on this device.';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPath();
  }

  Future<void> _loadSavedPath() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_savedPathKey);
    if (!mounted) return;
    setState(() {
      _savedPath = path != null && File(path).existsSync() ? path : null;
      if (_savedPath != null) _status = 'A local face sample is enrolled.';
    });
  }

  Future<void> _captureAndEnroll() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Opening camera…';
    });
    try {
      final XFile? capture = await _picker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.front,
        imageQuality: 92,
      );
      if (capture == null) {
        _setStatus('Capture cancelled. No changes were made.');
        return;
      }

      _setStatus('Checking image for a face on this device…');
      final faces = await _detector.processImage(
        InputImage.fromFilePath(capture.path),
      );
      if (faces.length != 1) {
        _setStatus(faces.isEmpty
            ? 'No face detected. Use good lighting and face the camera.'
            : 'More than one face detected. Capture only your face.');
        return;
      }

      final directory = await getApplicationSupportDirectory();
      final destination = File('${directory.path}/almus_face_sample.jpg');
      await File(capture.path).copy(destination.path);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_savedPathKey, destination.path);
      if (!mounted) return;
      setState(() {
        _savedPath = destination.path;
        _status = 'Face detected and sample saved privately on this device. '
            'Identity matching is not enabled yet.';
      });
    } catch (_) {
      _setStatus('Could not process the photo. Check camera availability and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setStatus(String value) {
    if (mounted) setState(() => _status = value);
  }

  Future<void> _deleteEnrollment() async {
    final path = _savedPath;
    try {
      if (path != null) {
        final file = File(path);
        if (await file.exists()) await file.delete();
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_savedPathKey);
      if (!mounted) return;
      setState(() {
        _savedPath = null;
        _status = 'Local face sample deleted.';
      });
    } catch (_) {
      _setStatus('Could not delete the sample. Please try again.');
    }
  }

  @override
  void dispose() {
    _detector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSample = _savedPath != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Face Recognition · Phase 9')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [theme.colorScheme.primaryContainer, theme.colorScheme.surface],
              ),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(children: [
              Icon(Icons.face_retouching_natural, size: 76, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('ON-DEVICE FACE DETECTION',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              Text(hasSample ? 'FACE SAMPLE ENROLLED' : 'NO FACE SAMPLE',
                  style: TextStyle(fontWeight: FontWeight.bold, color: hasSample ? Colors.green : theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(height: 18),
          Text(_status, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _captureAndEnroll,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.camera_alt_outlined),
            label: Text(_busy ? 'PROCESSING…' : hasSample ? 'RE-ENROLL FACE SAMPLE' : 'CAPTURE & ENROLL FACE'),
          ),
          if (hasSample) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _deleteEnrollment,
              icon: const Icon(Icons.delete_outline),
              label: const Text('DELETE SAVED SAMPLE'),
            ),
          ],
          const SizedBox(height: 22),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('IMPORTANT SECURITY LIMIT', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                const Text(
                  'This phase uses Google ML Kit to detect a face and checks that exactly one face is in the captured photo. Face detection is not identity recognition: it cannot prove that the next face belongs to the enrolled person. This sample is not used to unlock Almus AI.',
                ),
                const SizedBox(height: 8),
                const Text(
                  'The image is stored in the app-private files area and is not uploaded. For secure access, keep Android biometric authentication enabled.',
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
