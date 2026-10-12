import 'dart:ui' show Color;

/// The numbers the painter needs for one frame.
///
/// This is the single contract between "what the avatar is doing" (the
/// animator) and "how it is drawn" (a renderer). A future 3D renderer can
/// consume the same values (blink -> eyelid blendshape, gaze -> eye bones,
/// headTilt/headYaw -> neck, mouthOpen/smile -> jaw and mouth shapes).
///
/// Owned and mutated by [AvatarAnimator]; renderers must only read it.
class AvatarPose {
  AvatarPose({required this.accent});

  Color accent;

  /// Eye size multipliers (state driven) and eyelid openness (blink driven).
  double eyeScaleX = 1;
  double eyeScaleY = 1;
  double eyeOpen = 1;

  /// Gaze direction, each -1..1.
  double gazeX = 0;
  double gazeY = 0;

  /// Head roll in radians, yaw parallax -1..1 and vertical bob in units.
  double headTilt = 0;
  double headYaw = 0;
  double headBob = 0;

  /// Breathing 0..1.
  double breath = 0;

  /// Mouth: smile -1 (frown) .. 1 (grin), slant -1..1, open 0..1, width 0..1.
  double smile = 0.5;
  double slant = 0;
  double mouthOpen = 0;
  double mouthWidth = 1;

  /// Glow strength around the avatar, 0..1.
  double aura = 0.2;

  /// Fade-in amounts (0..1) of state specific overlays.
  double ripple = 0;
  double dots = 0;
  double crossEyes = 0;
  double happyEyes = 0;
  double cheek = 0.28;

  /// Ear-pod glow and antenna orb brightness, 0..1.
  double podGlow = 0.75;
  double orbAlpha = 1;

  /// Seconds since the animator started (drives ripples, dots).
  double time = 0;
}
