import 'package:flutter/material.dart';

import '../app/app_services.dart';
import '../app/app_settings.dart';
import '../app/tracking_controller.dart';
import 'camera_preview.dart';

/// Whether the camera feed should be shown behind a menu that wants it: the setting is on (or
/// [force]) and the shared feed rule ([cameraFeedState], the same one the in-game inset uses)
/// has something live or paused to show.
bool menuCameraVisible(TrackingController t, AppSettings settings, {bool force = false}) {
  if (!(force || settings.showMenuCamera)) return false;
  return cameraFeedState(t, simulated: settings.simulatedInput) != CameraFeedState.hidden;
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

  /// True only on screens that intentionally show the feed behind them. A running stream alone
  /// never puts the feed behind a screen.
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

/// The game's camera view ([CameraFeedView], exactly what the in-game inset shows: same frames,
/// decoder, fit/mirror/rotation, hand overlay and pointer area) at full window size. The only
/// menu-specific parts are presentation: a readability tint, because menu panels sit on top of
/// it, and a caption. Ignores pointer input entirely, so mouse and hand-dwell controls above it
/// work unchanged.
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
    final simulated = s.settings.simulatedInput;
    if (visible != null) return visible! ? _feed(t, simulated) : const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([t, s.settings]),
      builder: (context, _) {
        if (menuCameraVisible(t, s.settings, force: forceVisible)) return _feed(t, s.settings.simulatedInput);
        return showFallback ? _fallback(t, s.settings.simulatedInput) : const SizedBox.shrink();
      },
    );
  }

  Widget _feed(TrackingController t, bool simulated) {
    final live = cameraFeedState(t, simulated: simulated) == CameraFeedState.live;
    return IgnorePointer(
      child: Stack(fit: StackFit.expand, children: [
        CameraFeedView(controller: t, simulated: simulated),
        // Readability tint: darker at the edges where most panels sit.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(radius: 1.1, colors: [Color(0x55120B26), Color(0xAA0B0720)]),
          ),
        ),
        if (live)
          const Positioned(
            left: 16,
            bottom: 12,
            child: Text(
              'GLASSES VIEW · dashed box = hand pointer area',
              style: TextStyle(fontFamily: 'Georgia', fontSize: 12, letterSpacing: 1.5, fontWeight: FontWeight.w700, color: Color(0xCCF3E6C8)),
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
