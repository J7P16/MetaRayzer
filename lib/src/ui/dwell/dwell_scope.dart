import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../input/hand_input.dart';
import 'dwell_selector.dart';

/// Visual state shared with targets and the cursor painter.
@immutable
class DwellVisual {
  const DwellVisual({this.cursor, this.hovered, this.progress = 0, this.locked = false, this.flashTarget, this.flash = 0, this.handLost = false});

  final Offset? cursor;
  final Object? hovered;
  final double progress;
  final bool locked;
  final Object? flashTarget;

  /// 1 right after an activation, fading to 0.
  final double flash;

  /// The hand is in "lost" status (cursor frozen at last position).
  final bool handLost;
}

/// Hand-controlled UI: draws a hand cursor over its subtree and activates [DwellTarget]s after
/// the configured dwell time. Mouse clicks work at the same time.
///
/// Both routes go through [DwellScopeState.guardedActivate]: a target activated by either the
/// mouse or the hand is locked against the hand for the rest of that hover, and any activation
/// blocks all others for [DwellScope.activationCooldown] (so a click and a dwell completing
/// together fire once, and a screen transition can't be double-triggered).
///
/// This is the UI interaction system only; in-game gestures are handled separately by the game.
class DwellScope extends StatefulWidget {
  const DwellScope({
    super.key,
    required this.enabled,
    required this.input,
    required this.dwellSeconds,
    required this.child,
    this.mapper = const CursorMapper(),
    this.onHoverStart,
    this.onActivated,
  });

  /// Minimum time between any two activations.
  static const Duration activationCooldown = Duration(milliseconds: 400);

  final bool enabled;
  final ValueListenable<HandInputFrame> input;
  final double dwellSeconds;
  final CursorMapper mapper;
  final Widget child;

  /// UI feedback hooks (sounds).
  final VoidCallback? onHoverStart;
  final VoidCallback? onActivated;

  /// The enclosing scope; registers a dependency so targets rebuild when it is toggled.
  static DwellScopeState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_DwellInherited>()?.state;

  @override
  State<DwellScope> createState() => DwellScopeState();
}

class DwellScopeState extends State<DwellScope> with SingleTickerProviderStateMixin {
  final Map<Object, ({GlobalKey key, VoidCallback onActivate})> _targets = {};
  final ValueNotifier<DwellVisual> visual = ValueNotifier(const DwellVisual());
  final GlobalKey _areaKey = GlobalKey();
  late final DwellSelector _selector = DwellSelector(dwellSeconds: widget.dwellSeconds);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  /// Frame time accumulated by this scope's ticker (deterministic, and paused with the scope).
  double _timeline = 0;
  double? _lastActivation;
  Object? _lastHovered;

  bool get enabled => widget.enabled;

  /// The single entry point for activating a target, from the mouse or the hand. Returns
  /// whether the activation happened.
  bool guardedActivate(Object id, VoidCallback onActivate) {
    final last = _lastActivation;
    final cooldown = DwellScope.activationCooldown.inMicroseconds / 1e6;
    if (widget.enabled && last != null && _timeline - last < cooldown) return false;
    _lastActivation = _timeline;
    _selector.lockOn(id);
    widget.onActivated?.call();
    onActivate();
    return true;
  }

  void register(Object id, GlobalKey key, VoidCallback onActivate) => _targets[id] = (key: key, onActivate: onActivate);
  void unregister(Object id) => _targets.remove(id);

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _ticker.start();
  }

  @override
  void didUpdateWidget(DwellScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selector.dwellSeconds = widget.dwellSeconds;
    if (widget.enabled && !_ticker.isActive) {
      _last = Duration.zero;
      _lastActivation = null; // a fresh screen context
      _ticker.start();
    } else if (!widget.enabled && _ticker.isActive) {
      _ticker.stop();
      _selector.reset();
      visual.value = const DwellVisual();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _timeline += dt;
    final area = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (area == null || !area.hasSize) return;

    final frame = widget.input.value;
    final hasCursor = (frame.status == HandTrackingStatus.tracking || frame.status == HandTrackingStatus.lost) && frame.position != null;
    final cursor = hasCursor ? widget.mapper.map(frame.position!, area.size, simulated: frame.simulated) : null;

    // Target rects in this scope's coordinates.
    final rects = <Object, Rect>{};
    for (final MapEntry(:key, :value) in _targets.entries) {
      final box = value.key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      final topLeft = box.localToGlobal(Offset.zero, ancestor: area);
      rects[key] = topLeft & box.size;
    }

    final activated = _selector.update(cursor, dt.clamp(0.0, 0.1), rects);
    if (activated != null) {
      final target = _targets[activated];
      if (target != null) guardedActivate(activated, target.onActivate);
    }
    if (_selector.hovered != null && _selector.hovered != _lastHovered) widget.onHoverStart?.call();
    _lastHovered = _selector.hovered;

    final sinceFlash = _selector.secondsSinceActivation;
    visual.value = DwellVisual(
      cursor: cursor,
      hovered: _selector.hovered,
      progress: _selector.progress,
      locked: _selector.hoveredIsLocked,
      flashTarget: _selector.lastActivated,
      flash: sinceFlash < 0.5 ? 1 - sinceFlash / 0.5 : 0,
      handLost: frame.status == HandTrackingStatus.lost,
    );
  }

  @override
  void dispose() {
    _ticker.dispose();
    visual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(key: _areaKey, fit: StackFit.expand, children: [
      _DwellInherited(state: this, enabled: widget.enabled, child: widget.child),
      if (widget.enabled)
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<DwellVisual>(
              valueListenable: visual,
              builder: (_, v, _) => CustomPaint(painter: _HandCursorPainter(v)),
            ),
          ),
        ),
    ]);
  }
}

class _HandCursorPainter extends CustomPainter {
  _HandCursorPainter(this.v);
  final DwellVisual v;

  @override
  void paint(Canvas canvas, Size size) {
    final c = v.cursor;
    if (c == null) return;
    const gold = Color(0xFFFFD27A);
    final alpha = v.handLost ? 0.4 : 1.0;
    // Glow + core.
    canvas.drawCircle(c, 22, Paint()..shader = RadialGradient(colors: [gold.withValues(alpha: 0.45 * alpha), gold.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: 22)));
    canvas.drawCircle(c, 7, Paint()..color = Colors.white.withValues(alpha: 0.95 * alpha));
    canvas.drawCircle(c, 14, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = gold.withValues(alpha: 0.6 * alpha));
    // Dwell progress ring.
    if (v.hovered != null && !v.locked && v.progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: 18),
        -math.pi / 2,
        2 * math.pi * v.progress,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..strokeCap = StrokeCap.round
          ..color = gold,
      );
    }
    // Activation burst.
    if (v.flash > 0) {
      canvas.drawCircle(c, 18 + (1 - v.flash) * 26, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = gold.withValues(alpha: v.flash));
    }
  }

  @override
  bool shouldRepaint(_HandCursorPainter old) => true;
}

/// Makes [child] selectable by hand dwell. Wrap ordinary buttons; their normal mouse behavior is
/// unchanged. While hovered by the hand cursor the child gets a glowing outline that fills as
/// the dwell progresses.
class DwellTarget extends StatefulWidget {
  const DwellTarget({super.key, required this.onActivate, required this.child, this.borderRadius = 14});

  /// For a mouse/keyboard press inside a [DwellTarget]: activates it through the shared guard,
  /// so a simultaneous hand dwell on the same control can't fire it a second time.
  static void activateFromPointer(BuildContext context) =>
      context.findAncestorStateOfType<_DwellTargetState>()?._activateFromPointer();

  final VoidCallback? onActivate;
  final Widget child;
  final double borderRadius;

  @override
  State<DwellTarget> createState() => _DwellTargetState();
}

class _DwellTargetState extends State<DwellTarget> {
  final GlobalKey _key = GlobalKey();
  DwellScopeState? _scope;

  void _activate() => widget.onActivate?.call();

  void _activateFromPointer() {
    final callback = widget.onActivate;
    if (callback == null) return;
    final scope = _scope;
    if (scope == null) {
      callback();
    } else {
      scope.guardedActivate(this, callback);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = DwellScope.maybeOf(context);
    if (scope != _scope) {
      _scope?.unregister(this);
      _scope = scope;
    }
    _syncRegistration();
  }

  @override
  void didUpdateWidget(DwellTarget old) {
    super.didUpdateWidget(old);
    _syncRegistration();
  }

  void _syncRegistration() {
    if (widget.onActivate == null) {
      _scope?.unregister(this);
    } else {
      _scope?.register(this, _key, _activate);
    }
  }

  @override
  void dispose() {
    _scope?.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    final child = KeyedSubtree(key: _key, child: widget.child);
    if (scope == null || !scope.enabled) return child;
    return ValueListenableBuilder<DwellVisual>(
      valueListenable: scope.visual,
      child: child,
      builder: (context, v, child) {
        final hovered = v.hovered == this;
        final flashing = v.flashTarget == this && v.flash > 0;
        if (!hovered && !flashing) return child!;
        const gold = Color(0xFFFFD27A);
        final glow = flashing ? v.flash : (v.locked ? 0.25 : 0.35 + 0.65 * v.progress);
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(color: gold.withValues(alpha: glow), width: 2 + 2 * glow),
            boxShadow: [BoxShadow(color: gold.withValues(alpha: 0.5 * glow), blurRadius: 18 * glow)],
          ),
          child: child,
        );
      },
    );
  }
}

class _DwellInherited extends InheritedWidget {
  const _DwellInherited({required this.state, required this.enabled, required super.child});
  final DwellScopeState state;
  final bool enabled;

  @override
  bool updateShouldNotify(_DwellInherited old) => old.enabled != enabled || old.state != state;
}
