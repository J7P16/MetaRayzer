import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/app_settings.dart';
import '../app/tracking_controller.dart';
import '../geometry/view_mapping.dart';
import 'camera_preview.dart';
import 'camera_stream_indicator.dart';
import 'dwell/dwell_selector.dart';

/// Whether the live camera feed should be shown behind the menus: the setting is on (or
/// [force]), a frame exists, and the stream is live, a dev feed, or stalled (shown as paused).
bool menuCameraVisible(TrackingController t, AppSettings settings, {bool force = false}) {
  if (!(force || settings.showMenuCamera) || !t.hasFrame) return false;
  final state = cameraStreamState(t);
  return state == CameraStreamState.live || state == CameraStreamState.dev || state == CameraStreamState.stalled;
}

/// Tells menu backgrounds ([FantasyBackground]) that the camera feed is showing behind them, so
/// they draw a translucent tint instead of the opaque night sky.
class MenuBackdropScope extends InheritedWidget {
  const MenuBackdropScope({super.key, required this.active, required super.child});
  final bool active;

  static bool activeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<MenuBackdropScope>()?.active ?? false;

  @override
  bool updateShouldNotify(MenuBackdropScope old) => old.active != active;
}

/// Hosts the menu screens over the shared camera backdrop. The backdrop widget stays in the
/// tree in every state (it renders nothing while inactive), so toggling it never rebuilds or
/// resets the screens, and the camera stream itself is never restarted by navigation.
class MenuBackdropHost extends StatelessWidget {
  const MenuBackdropHost({super.key, required this.allowed, required this.child});

  /// False on routes that show the camera themselves (gameplay, tutorial, tracking setup).
  final bool allowed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.tracking, s.settings]),
      child: child,
      builder: (context, child) {
        final active = allowed && menuCameraVisible(s.tracking, s.settings);
        return Stack(fit: StackFit.expand, children: [
          MenuCameraBackdrop(visible: active),
          MenuBackdropScope(active: active, child: child!),
        ]);
      },
    );
  }
}

/// The live glasses view, full-window, with the same fit/mirror/rotation (and so the same hand
/// coordinates) as the gameplay camera inset, the existing hand-dot overlay, and an outline of
/// the hand-pointer area. Dimmed so menus stay readable; ignores pointer input entirely.
class MenuCameraBackdrop extends StatelessWidget {
  const MenuCameraBackdrop({super.key, this.visible, this.forceVisible = false, this.showFallback = false});

  /// Externally decided visibility (null: decide here).
  final bool? visible;

  /// Show whenever a feed exists, regardless of the menu setting (tutorial step 1).
  final bool forceVisible;

  /// With no feed, show a short explanation instead of nothing.
  final bool showFallback;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = s.tracking;
    if (visible != null) return visible! ? _feed(t) : const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([t, s.settings]),
      builder: (context, _) {
        if (menuCameraVisible(t, s.settings, force: forceVisible)) return _feed(t);
        return showFallback ? _fallback(t, s.settings.simulatedInput) : const SizedBox.shrink();
      },
    );
  }

  Widget _feed(TrackingController t) {
    final stalled = cameraStreamState(t) == CameraStreamState.stalled;
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        Opacity(opacity: stalled ? 0.35 : 1, child: CameraPreview(controller: t)),
        // Readability tint: darker at the edges where most panels sit.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(radius: 1.1, colors: [Color(0x55120B26), Color(0xAA0B0720)]),
          ),
        ),
        CustomPaint(painter: _PointerAreaPainter(t)),
        Positioned(
          left: 16,
          bottom: 12,
          child: Text(
            stalled ? 'STREAM PAUSED · showing the last frame' : 'GLASSES VIEW · dashed box = hand pointer area',
            style: TextStyle(fontFamily: 'Georgia', fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w700, color: stalled ? const Color(0xFFFFC857) : const Color(0xCCF3E6C8)),
          ),
        ),
      ]),
    );
  }

  Widget _fallback(TrackingController t, bool simulated) {
    final text = simulated
        ? 'Simulated input: no camera feed. Use the mouse as your hand.'
        : (t.companionConnected ? 'Glasses connected, camera not streaming. Start the stream from the menu or the companion.' : 'Glasses not connected: the camera view appears here once the companion streams.');
    return IgnorePointer(
      child: Align(
        alignment: const Alignment(0, 0.75),
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xCC120B26), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0x88FFC857))),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.videocam_off_outlined, color: Color(0xFFFFC857), size: 18),
              const SizedBox(width: 10),
              Text(text, style: const TextStyle(fontFamily: 'Georgia', fontSize: 14, color: Color(0xFFF3E6C8))),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Outlines the camera region the menu cursor and staff use (the [CursorMapper] interaction
/// box), mapped with the same [FrameViewMapping] as the picture.
class _PointerAreaPainter extends CustomPainter {
  _PointerAreaPainter(this.t);
  final TrackingController t;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = t.frame;
    if (frame == null) return;
    final mapping = FrameViewMapping(
      frameSize: Size(frame.width.toDouble(), frame.height.toDouble()),
      viewSize: size,
      fit: t.fit,
      mirrored: t.mirrored,
      quarterTurns: t.quarterTurns,
    );
    final image = mapping.imageRect;
    final box = const CursorMapper().box;
    final r = Rect.fromLTRB(image.left + box.left * image.width, image.top + box.top * image.height, image.left + box.right * image.width, image.top + box.bottom * image.height);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = const Color(0x99FFD27A);
    for (final (a, b) in [(r.topLeft, r.topRight), (r.topRight, r.bottomRight), (r.bottomRight, r.bottomLeft), (r.bottomLeft, r.topLeft)]) {
      final d = (b - a).distance;
      final dir = (b - a) / d;
      for (var x = 0.0; x < d; x += 16) {
        canvas.drawLine(a + dir * x, a + dir * (x + 8).clamp(0, d), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_PointerAreaPainter old) => true;
}
