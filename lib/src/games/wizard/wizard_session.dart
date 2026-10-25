import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../input/head_pose.dart';
import '../../platform/minigame.dart';
import 'aim.dart';
import 'cast_gesture.dart';
import 'shield_gesture.dart';
import 'spell_switch.dart';
import 'view/arena_projection.dart';
import 'view/effects.dart';
import 'view/wizard_painter.dart';
import 'wizard_audio.dart';
import 'wizard_game.dart';

/// Everything that turns input into gameplay for one [WizardGame], shared by the real run screen
/// and the tutorial so both behave identically:
/// - hand → cast (fist→open), spell switch (held ✌) and shield (blocking pose);
/// - hand + head → staff, aim and shield direction;
/// - game events → effects and positioned sounds.
///
/// It owns no ticker and no route logic: the hosting screen calls [onHand] when the hand input
/// changes and [tick] once per frame, and decides what the returned events mean for the app
/// (persistence, results, tutorial steps).
class WizardSession {
  WizardSession({required this.host, required this.game}) {
    scene = WizardSceneState(game: game, effects: effects, staff: staff);
    audio = WizardAudio(host.audio);
  }

  final MinigameHost host;
  final WizardGame game;
  final CastGestureRecognizer gesture = CastGestureRecognizer();
  final SpellSwitchRecognizer spellSwitch = SpellSwitchRecognizer();
  final ShieldGestureRecognizer shieldGesture = ShieldGestureRecognizer();
  final StaffAim staff = StaffAim();
  final WizardEffects effects = WizardEffects();
  late final WizardAudio audio;
  late final WizardSceneState scene;
  Size size = const Size(1280, 800);

  /// Casting can be turned off (tutorial steps that teach something else).
  bool castingEnabled = true;

  /// Called after every cast attempt (tutorial feedback).
  void Function(CastResult result)? onCastResult;

  /// Hand input changed: update the gesture recognizers.
  void onHand() {
    final frame = host.handInput.value;
    scene.hand = frame;
    scene.simulated = frame.simulated;
    shieldGesture.update(frame);
    game.setShieldPose(shieldGesture.held);
    scene.shieldReadiness = shieldGesture.readiness;
    if (shieldGesture.candidate || shieldGesture.held) {
      // A raised blocking hand must never also fire (or keep armed) a spell.
      gesture.reset();
      spellSwitch.reset();
    } else {
      if (spellSwitch.update(frame)) switchSpell();
      if (gesture.update(frame) && castingEnabled) cast();
    }
    scene.gesture = gesture.feedback;
  }

  void switchSpell() {
    // Require a fresh fist after switching, so the switch can't trigger an unintended cast.
    if (game.cycleSpell()) gesture.reset();
  }

  void selectSpell(String id) {
    if (game.selectSpell(id)) gesture.reset();
  }

  void cast() {
    final result = game.cast();
    if (result == CastResult.launched || result == CastResult.noTargetInRange) {
      final color = spellColor(game.selectedSpell);
      effects.onCast(color);
      effects.emitStaffSparks(staff.tipOnScreen(size), color, count: 16, speed: 220);
    }
    debugPrint('[metarayzer] ${game.selectedSpell} cast: ${result.name} (score ${game.score}, lives ${game.lives})');
    onCastResult?.call(result);
  }

  /// Shared keys: Q/Tab switch spells, R recenters the head, and in simulated input V = ✌,
  /// B = blocking pose, arrows = head turn. Returns whether the key was handled.
  bool handleKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (down && (key == LogicalKeyboardKey.keyQ || key == LogicalKeyboardKey.tab)) {
      switchSpell();
      return true;
    }
    if (down && key == LogicalKeyboardKey.keyR) {
      host.headInput.recenter();
      return true;
    }
    if (host.settings.simulatedInput && event is! KeyRepeatEvent) {
      if (key == LogicalKeyboardKey.keyV) {
        host.handInput.simulated.setVictory(down);
        return true;
      }
      if (key == LogicalKeyboardKey.keyB) {
        host.handInput.simulated.setBlock(down);
        return true;
      }
      final turn = switch (key) {
        LogicalKeyboardKey.arrowLeft => (-1.0, 0.0),
        LogicalKeyboardKey.arrowRight => (1.0, 0.0),
        LogicalKeyboardKey.arrowUp => (0.0, 1.0),
        LogicalKeyboardKey.arrowDown => (0.0, -1.0),
        _ => null,
      };
      if (turn != null) {
        host.headInput.setSimulatedTurn(yaw: down ? turn.$1 : 0, pitch: down ? turn.$2 : 0);
        return true;
      }
    }
    return false;
  }

  /// Advances one frame: head + staff → aim, simulation, effects and sound. Returns the game
  /// events of this frame for the host screen.
  List<GameEvent> tick(double dt) {
    scene.time += dt;
    final nowMs = scene.time * 1000;

    final head = host.headInput.view(sensitivity: host.settings.headSensitivity, invertYaw: host.settings.invertHeadYaw);
    scene.head = head;
    staff.update(host.handInput.value, nowMs);
    game.aimYaw = staff.worldAimYaw(head.status == HeadTrackingStatus.unavailable ? 0 : head.yaw);

    game.update(dt);
    gesture.tick();
    scene.gesture = gesture.feedback;

    final events = game.drainEvents();
    effects.consume(events);
    audio.consume(events);
    audio.tick(dt);
    host.audio.setListenerYaw(head.yaw);

    // Fireball trails and staff sparks (view-only particles).
    final projection = ArenaProjection(size, yaw: head.yaw, pitch: head.pitch);
    final tip = staff.tipOnScreen(size);
    for (final f in game.fireballs) {
      effects.emitTrail(WizardPainter.fireballScreenPosition(size, projection, f, tip), 14, dt: dt);
    }
    if (gesture.feedback.phase == CastPhase.charging && scene.time % 0.1 < dt) {
      effects.emitStaffSparks(tip, spellColor(game.selectedSpell), count: 2, speed: 60);
    }
    effects.update(dt);
    return events;
  }
}
