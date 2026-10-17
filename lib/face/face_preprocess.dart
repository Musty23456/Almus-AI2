import 'dart:math' as math;
import 'dart:typed_data';

import 'face_model_manifest.dart';
import 'face_models.dart';

/// Plain 8-bit RGB pixels, row by row (3 bytes per pixel).
class RgbImage {
  RgbImage(this.width, this.height, this.rgb)
      : assert(rgb.length == width * height * 3);

  factory RgbImage.filled(int width, int height, int r, int g, int b) {
    final Uint8List data = Uint8List(width * height * 3);
    for (int i = 0; i < data.length; i += 3) {
      data[i] = r;
      data[i + 1] = g;
      data[i + 2] = b;
    }
    return RgbImage(width, height, data);
  }

  final int width;
  final int height;
  final Uint8List rgb;

  void setPixel(int x, int y, int r, int g, int b) {
    final int o = (y * width + x) * 3;
    rgb[o] = r;
    rgb[o + 1] = g;
    rgb[o + 2] = b;
  }

  /// Bilinear sample; coordinates outside the picture use the nearest edge.
  List<double> sample(double x, double y) {
    final double cx = x.clamp(0.0, width - 1.0).toDouble();
    final double cy = y.clamp(0.0, height - 1.0).toDouble();
    final int x0 = cx.floor();
    final int y0 = cy.floor();
    final int x1 = math.min(x0 + 1, width - 1);
    final int y1 = math.min(y0 + 1, height - 1);
    final double fx = cx - x0;
    final double fy = cy - y0;
    final List<double> out = <double>[0, 0, 0];
    for (int c = 0; c < 3; c++) {
      final double a = rgb[(y0 * width + x0) * 3 + c].toDouble();
      final double b = rgb[(y0 * width + x1) * 3 + c].toDouble();
      final double d = rgb[(y1 * width + x0) * 3 + c].toDouble();
      final double e = rgb[(y1 * width + x1) * 3 + c].toDouble();
      final double top = a + (b - a) * fx;
      final double bottom = d + (e - d) * fx;
      out[c] = top + (bottom - top) * fy;
    }
    return out;
  }
}

/// Rotates, scales and crops [src] so the two eyes land on the model's
/// expected eye positions, producing a square [size] x [size] picture.
/// This is a similarity transform (rotation + uniform scale + shift).
/// Returns null when the eyes are too close together to be real.
RgbImage? alignFace(
  RgbImage src,
  FacePoint leftEye,
  FacePoint rightEye,
  FaceModelManifest manifest,
) {
  final int size = manifest.inputSize;
  final double sdx = rightEye.x - leftEye.x;
  final double sdy = rightEye.y - leftEye.y;
  final double srcDist = math.sqrt(sdx * sdx + sdy * sdy);
  final double tdx = manifest.eyeRight.x - manifest.eyeLeft.x;
  final double tdy = manifest.eyeRight.y - manifest.eyeLeft.y;
  final double tgtDist = math.sqrt(tdx * tdx + tdy * tdy);
  if (srcDist < 4 || tgtDist < 1) return null;

  final double scale = srcDist / tgtDist; // source pixels per output pixel
  final double angle = math.atan2(sdy, sdx) - math.atan2(tdy, tdx);
  final double cosA = math.cos(angle);
  final double sinA = math.sin(angle);

  final RgbImage out = RgbImage(size, size, Uint8List(size * size * 3));
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double px = (x - manifest.eyeLeft.x) * scale;
      final double py = (y - manifest.eyeLeft.y) * scale;
      final double sx = leftEye.x + px * cosA - py * sinA;
      final double sy = leftEye.y + px * sinA + py * cosA;
      final List<double> c = src.sample(sx, sy);
      out.setPixel(x, y, _byte(c[0]), _byte(c[1]), _byte(c[2]));
    }
  }
  return out;
}

int _byte(double v) {
  final int r = v.round();
  if (r < 0) return 0;
  if (r > 255) return 255;
  return r;
}

/// Mean brightness (0-255, Rec. 601 weights) of [img].
double meanLuma(RgbImage img) {
  double sum = 0;
  final int n = img.width * img.height;
  if (n == 0) return 0;
  for (int i = 0; i < img.rgb.length; i += 3) {
    sum += 0.299 * img.rgb[i] + 0.587 * img.rgb[i + 1] + 0.114 * img.rgb[i + 2];
  }
  return sum / n;
}

/// NHWC float tensor: (pixel - mean) / std for every channel value.
Float32List toTensor(RgbImage img, FaceModelManifest manifest) {
  final Float32List t = Float32List(img.rgb.length);
  for (int i = 0; i < img.rgb.length; i++) {
    t[i] = (img.rgb[i] - manifest.inputMean) / manifest.inputStd;
  }
  return t;
}
