# Face recognition model: licensing and runtime assessment (Phase 6)

**Result: no face-recognition model is bundled or downloaded.** None could be
verified as having a clear licence for this use. The app ships the full
pipeline around a model, and refuses to recognise anyone until a verified,
checksummed and calibrated model is installed. Nothing pretends to recognise.

This assessment was done from a sandbox with **no network access for
downloads**: no model file was downloaded, opened or measured. Only public
web pages were read. Anything marked *unverified* below is exactly that.

## What was checked

| Candidate | Finding | Decision |
|---|---|---|
| Google ML Kit Face Detection (already in the app) | Detects faces and landmarks. It returns **no identity and no embedding**; it cannot recognise a person. | Keep for detection only. |
| InsightFace pretrained recognition models (e.g. `buffalo_l`, `buffalo_s`, `buffalo_sc`, ArcFace ResNet) | The InsightFace **code** is MIT, but the project states that the training data and **the models trained on it are for non-commercial research use only**, for both manual and auto-downloaded models, and that licensing of the open-sourced recognition models (e.g. `buffalo_l`) must be requested from the authors. | **Excluded.** A personal app is not "research", and commercial use is explicitly outside the licence. A written licence from the authors would be needed. |
| MobileFaceNet / FaceNet / SFace (OpenCV Zoo) and community TFLite conversions | Code licences are often permissive (MIT / Apache-2.0), but I could **not verify the licence of the trained weights or the terms of the face datasets** they were trained on (large web-scraped face datasets such as MS-Celeb-1M-derived sets are common). Conversions by third parties add another unknown link. | **Excluded as unverified.** Do not assume these are safe because the GitHub repo says "Apache-2.0". |
| MediaPipe Face Detector / Landmarker | Detection and landmarks only, no identity embedding. | Not a recognition model. |
| Android's own face authentication | Not available to apps as an embedding or matching API; apps only receive pass/fail through `BiometricPrompt`. | Already used by the app lock (unchanged). |

Rule applied (from the Phase 6 brief): *do not download or use a model with
unclear licensing.* Unclear = excluded.

## Runtime (inference engine)

* **TensorFlow Lite / LiteRT through `tflite_flutter`**: Apache-2.0, supports
  fully offline CPU inference on Android. Version 0.12.1 (Oct 2025) moved to
  LiteRT 1.4.0 for 16 KB page-size support, and a community fork's page says
  its bundled native libraries need Android API 26+. I could not verify the
  last point for the upstream package. Because the plugin ships native code
  and I cannot compile here, **it is deliberately not added in this phase**; a
  broken native dependency would break your GitHub build for a feature that
  has no model to run yet.
* The code is runtime-agnostic: it talks to a small `FaceEmbedder` interface
  (`lib/face/face_ports.dart`). `UnavailableFaceEmbedder` is what the app uses
  today.

## Requirements a model must meet before it is installed

1. A licence file covering the **weights**, allowing your intended use
   (personal / commercial, as applicable). Keep a copy in `docs/`.
2. A statement of the **training data** and that its terms allow models
   trained on it to be used this way. If this cannot be written down, stop.
3. Android compatibility: `.tflite` (or another format your chosen runtime
   loads), float or int8 input, known input size and embedding length.
4. Offline inference: all files local; no download at run time.
5. Measured, on **your** phone: model file size, peak memory, time per
   embedding. (No figures are given here because none were measured.)
6. Distribution: the model file is not committed to GitHub unless its licence
   allows redistribution. The app reads it from the app-private folder
   `face_model/` and checks its SHA-256 against `manifest.json`.
7. A **calibrated threshold** from labelled data you are allowed to use
   (`tool/calibrate_threshold.py`). A model without it cannot match anyone.

## Security limitations of any such model

* A recognition model measures similarity, not identity. Similar-looking
  people (relatives, twins), age change, glasses, beards, masks, make-up and
  poor light all move scores.
* It has no notion of "live". Presentation attacks (photo, screen, video) are
  outside what the model does; see `FACE_ANTI_SPOOFING.md`.
* Accuracy differs between demographic groups and capture conditions; the
  public benchmark numbers of any model do **not** describe this app, its
  camera or its preprocessing.
* The embedding is biometric data. Handle it as such (`FACE_PRIVACY.md`).

## Binding a model (for a later phase)

1. Choose a model that passes the list above. Record its licence.
2. Add the runtime to `pubspec.yaml` (for example `tflite_flutter`), run the
   CI build once on its own, and fix any Gradle issues first.
3. Implement `FaceEmbedder` (load `face_model/model.tflite`, run on a
   background isolate, return the raw float vector). An *untested sketch*:

   ```dart
   class TfliteFaceEmbedder implements FaceEmbedder {
     TfliteFaceEmbedder(this._interpreter, this._dim);
     final Interpreter _interpreter; final int _dim;
     @override bool get isAvailable => true;
     @override String get unavailableReason => '';
     @override Future<Float32List> embed(Float32List tensor) async {
       final input = tensor.reshape([1, 112, 112, 3]);
       final output = List.filled(_dim, 0.0).reshape([1, _dim]);
       _interpreter.run(input, output);
       return Float32List.fromList((output[0] as List).cast<double>());
     }
     @override Future<void> close() async => _interpreter.close();
   }
   ```
4. In `buildFaceRuntime` (`lib/face/face_model_locator.dart`) call
   `locator.check(runtimeAvailable: true)` and, when the status is `ready`,
   return `FaceRuntime(embedder: TfliteFaceEmbedder(...), manifest: ...)`.
5. Write `manifest.json` (fields are in `lib/face/face_model_manifest.dart`),
   run the calibration tool, and complete `FACE_DEVICE_TEST_PLAN.md`.

I am not a lawyer; for any redistribution or commercial use, get the licence
checked by one.
