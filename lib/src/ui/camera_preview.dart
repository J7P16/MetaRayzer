import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller.dart';
import '../geometry/view_mapping.dart';
import 'hand_overlay_painter.dart';

/// Live camera frame with the hand overlay. The image is placed at exactly
/// [FrameViewMapping.imageRect] with the same rotation/mirroring the overlay uses, so dots and
/// picture always line up.
class CameraPreview extends StatelessWidget {
  const CameraPreview({super.key, required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final frame = c.frame;
    return LayoutBuilder(builder: (context, constraints) {
      if (frame == null) return _Placeholder(controller: c);
      final mapping = FrameViewMapping(
        frameSize: Size(frame.width.toDouble(), frame.height.toDouble()),
        viewSize: constraints.biggest,
        fit: c.fit,
        mirrored: c.mirrored,
        quarterTurns: c.quarterTurns,
      );
      return ClipRect(
        child: Stack(children: [
          const Positioned.fill(child: ColoredBox(color: Colors.black)),
          Positioned.fromRect(
            rect: mapping.imageRect,
            child: Transform.flip(
              flipX: c.mirrored,
              child: RotatedBox(quarterTurns: c.quarterTurns, child: LiveFrameImage(jpeg: frame.jpeg, seq: frame.seq)),
            ),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: HandOverlayPainter(
                mapping: mapping,
                hands: c.hands,
                showLandmarks: c.showLandmarks,
                showLabels: c.showDebug,
              ),
            ),
          ),
          if (c.source == FrameSource.webcam)
            const Positioned(left: 12, top: 12, child: _Badge('DEV FALLBACK · Mac webcam, not glasses', Colors.amber)),
          if (c.companionStatus['mock'] == true && c.source == FrameSource.companion)
            const Positioned(left: 12, top: 12, child: _Badge('DEV · mock feed (MockDeviceKit or dev sender), not real glasses', Colors.amber)),
          if (c.streamStalled)
            const Positioned(right: 12, top: 12, child: _Badge('Stream stalled: no new frames', Colors.redAccent)),
        ]),
      );
    });
  }
}

/// Decodes JPEG frames off the UI thread with latest-frame-wins semantics and disposes old
/// images eagerly (avoids filling the image cache with one-shot frames).
class LiveFrameImage extends StatefulWidget {
  const LiveFrameImage({super.key, required this.jpeg, required this.seq});
  final Uint8List jpeg;
  final int seq;

  @override
  State<LiveFrameImage> createState() => _LiveFrameImageState();
}

class _LiveFrameImageState extends State<LiveFrameImage> {
  ui.Image? _image;
  bool _decoding = false;
  Uint8List? _pending;

  @override
  void initState() {
    super.initState();
    _decode(widget.jpeg);
  }

  @override
  void didUpdateWidget(LiveFrameImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seq != widget.seq || !identical(oldWidget.jpeg, widget.jpeg)) _decode(widget.jpeg);
  }

  Future<void> _decode(Uint8List bytes) async {
    if (_decoding) {
      _pending = bytes;
      return;
    }
    _decoding = true;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = frame.image;
      });
    } catch (e) {
      debugPrint('[metarayzer] frame decode failed: $e');
    } finally {
      _decoding = false;
    }
    final next = _pending;
    _pending = null;
    if (next != null && mounted) _decode(next);
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawImage(image: _image, fit: BoxFit.fill, filterQuality: FilterQuality.low);
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: color.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(text, style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600, fontSize: 12)),
        ),
      );
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final info = c.serverInfo;
    final theme = Theme.of(context);
    final String headline;
    final String detail;
    if (c.source == FrameSource.webcam) {
      headline = 'Starting Mac webcam…';
      detail = 'Development fallback. Allow camera access if macOS asks.';
    } else if (c.server.state == 'failed') {
      headline = 'Companion listener failed';
      detail = c.server.message ?? '';
    } else if (!c.companionConnected) {
      headline = 'Waiting for the iPhone companion';
      detail = 'Open MetaRayzer Companion on your iPhone (same Wi-Fi). It finds this Mac automatically.\n'
          'Manual connection: ${info == null || info.addresses.isEmpty ? '<this Mac\'s IP>' : info.addresses.join(' or ')}'
          ' port ${info?.port ?? 47800}';
    } else {
      headline = 'Companion connected · no video yet';
      final stream = c.companionStatus['stream'] ?? 'unknown';
      detail = 'Glasses stream state: $stream. Press "Start glasses stream" '
          '(the glasses must be registered and camera permission granted in the companion).';
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.videocam_off_outlined, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(headline, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(detail, style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}
