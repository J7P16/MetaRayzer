import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller.dart';

enum CameraStreamState {
  /// No glasses/companion and no dev camera: nothing shown.
  none,

  /// The iPhone companion is connected, but the glasses camera stream is stopped.
  connected,

  /// Frames from the glasses camera are actively arriving in this app.
  live,

  /// The stream should be running but no frames are arriving.
  stalled,

  /// Development source: the Mac webcam (or a mock feed) is in use, not the glasses.
  dev,
}

CameraStreamState cameraStreamState(TrackingController t) {
  if (t.source == FrameSource.webcam) return t.hasFrame ? CameraStreamState.dev : CameraStreamState.none;
  if (!t.companionConnected) return CameraStreamState.none;
  final streaming = t.companionStatus['stream'] == 'streaming';
  if (t.companionStatus['mock'] == true && streaming) return CameraStreamState.dev;
  if (streaming && t.hasFrame && !t.streamStalled) return CameraStreamState.live;
  if (streaming) return CameraStreamState.stalled;
  return CameraStreamState.connected;
}

/// Shows whether MetaRayzer is receiving the glasses' camera stream right now.
///
/// It reflects THIS APP's camera stream (the companion's DAT stream state + frames arriving).
/// It does not read or control the glasses' own capture LED, which Meta manages on the device;
/// the toolkit exposes no API for it.
class CameraStreamIndicator extends StatelessWidget {
  const CameraStreamIndicator({super.key, required this.tracking});
  final TrackingController tracking;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tracking,
      builder: (context, _) {
        final state = cameraStreamState(tracking);
        if (state == CameraStreamState.none) return const SizedBox.shrink();
        final (String text, Color color, bool pulse) = switch (state) {
          CameraStreamState.live => ('LIVE · Glasses camera streaming to MetaRayzer', const Color(0xFFFF3B3B), true),
          CameraStreamState.stalled => ('Glasses stream stalled', const Color(0xFFFFC857), false),
          CameraStreamState.connected => ('Glasses connected · camera off', const Color(0xFF9A93AE), false),
          CameraStreamState.dev => ('DEV camera feed (not the glasses)', const Color(0xFFFFC857), false),
          CameraStreamState.none => ('', Colors.transparent, false),
        };
        return Tooltip(
          message: "Shows this app's use of the glasses camera stream. The glasses' own capture LED is controlled by Meta on the device.",
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xCC120B26),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withValues(alpha: 0.7)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                pulse ? _PulsingDot(color: color) : Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Text(text, style: TextStyle(fontFamily: 'Georgia', fontSize: 12, color: color, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});
  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Icon(Icons.circle, size: 10, color: widget.color.withValues(alpha: 0.55 + 0.45 * (0.5 + 0.5 * math.sin(_c.value * 2 * math.pi)))),
      );
}
