import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../audio/audio_service.dart';
import '../../input/head_pose.dart';
import '../../platform/minigame.dart';
import '../../ui/camera_preview.dart';
import '../../ui/camera_stream_indicator.dart';
import 'aim.dart';
import 'cast_gesture.dart';
import 'spell_switch.dart';
import 'view/arena_projection.dart';
import 'view/effects.dart';
import 'view/wizard_painter.dart';
import 'wizard_audio.dart';
import 'wizard_config.dart';
import 'wizard_game.dart';

const wizardShooter = MinigameDefinition(
  id: 'wizard_shooter',
  title: "Wizard's Stand",
  tagline: 'Hold the line against the horde with fire (and lightning) from your fingertips.',
  builder: _build,
);

Widget _build(BuildContext context, MinigameHost host) => WizardGameScreen(host: host);

/// Hosts one run: drives [WizardGame] from a ticker, turns hand input into casts and spell
/// switches, applies head pose + staff aim, and renders with [WizardPainter]. Leaving this widget
/// (results screen, Esc) disposes the ticker, so nothing keeps running in the background.
class WizardGameScreen extends StatefulWidget {
  const WizardGameScreen({super.key, required this.host, this.seed, this.config = const WizardConfig()});
  final MinigameHost host;
  final int? seed;
  final WizardConfig config;

  @override
  State<WizardGameScreen> createState() => WizardGameScreenState();
}

class WizardGameScreenState extends State<WizardGameScreen> with SingleTickerProviderStateMixin {
  late final WizardGame _game = WizardGame(seed: widget.seed, config: widget.config, unlockedSpells: host.progression.unlocked);
  final CastGestureRecognizer _gesture = CastGestureRecognizer();
  final SpellSwitchRecognizer _spellSwitch = SpellSwitchRecognizer();
  final StaffAim _staff = StaffAim();
  final WizardEffects _effects = WizardEffects();
  late final WizardAudio _audio = WizardAudio(host.audio);
  late final WizardSceneState _scene = WizardSceneState(game: _game, effects: _effects, staff: _staff);
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _finishing = false;
  Timer? _finishTimer;
  Size _size = const Size(1280, 800);

  MinigameHost get host => widget.host;

  @visibleForTesting
  WizardGame get game => _game;

  @override
  void initState() {
    super.initState();
    host.handInput.addListener(_onHand);
    host.headInput.simulated = host.settings.simulatedInput;
    HardwareKeyboard.instance.addHandler(_onKey);
    host.audio.ambientOn = true;
    host.audio.play(Sounds.gameStart, positional: false);
    _onHand();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _finishTimer?.cancel();
    host.handInput.removeListener(_onHand);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _repaint.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final key = event.logicalKey;
    final down = event is KeyDownEvent;
    if (down && (key == LogicalKeyboardKey.keyQ || key == LogicalKeyboardKey.tab)) {
      _switchSpell();
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

  void _switchSpell() {
    if (_game.cycleSpell()) {
      // Require a fresh fist after switching, so the switch can't trigger an unintended cast.
      _gesture.reset();
    }
  }

  void _onHand() {
    final frame = host.handInput.value;
    _scene.hand = frame;
    _scene.simulated = frame.simulated;
    if (_spellSwitch.update(frame)) _switchSpell();
    if (_gesture.update(frame)) _cast();
    _scene.gesture = _gesture.feedback;
  }

  void _cast() {
    final result = _game.cast();
    if (result == CastResult.launched || result == CastResult.noTargetInRange) {
      final color = spellColor(_game.selectedSpell);
      _effects.onCast(color);
      _effects.emitStaffSparks(_staff.tipOnScreen(_size), color, count: 16, speed: 220);
    }
    debugPrint('[metarayzer] ${_game.selectedSpell} cast: ${result.name} (score ${_game.score}, lives ${_game.lives})');
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _scene.time += dt;
    final nowMs = _scene.time * 1000;

    final head = host.headInput.view(sensitivity: host.settings.headSensitivity, invertYaw: host.settings.invertHeadYaw);
    _scene.head = head;
    _staff.update(host.handInput.value, nowMs);
    _game.aimYaw = _staff.worldAimYaw(head.status == HeadTrackingStatus.unavailable ? 0 : head.yaw);

    _game.update(dt);
    _gesture.tick();
    _scene.gesture = _gesture.feedback;

    final events = _game.drainEvents();
    for (final e in events) {
      if (e is SpellUnlocked) host.progression.unlock(e.spellId); // persisted once
    }
    _effects.consume(events);
    _audio.consume(events);
    _audio.tick(dt);
    host.audio.setListenerYaw(head.yaw);

    // Fireball trails and staff sparks (view-only particles).
    final projection = ArenaProjection(_size, yaw: head.yaw, pitch: head.pitch);
    final tip = _staff.tipOnScreen(_size);
    for (final f in _game.fireballs) {
      _effects.emitTrail(WizardPainter.fireballScreenPosition(_size, projection, f, tip), 14, dt: dt);
    }
    if (_gesture.feedback.phase == CastPhase.charging && _scene.time % 0.1 < dt) {
      _effects.emitStaffSparks(tip, spellColor(_game.selectedSpell), count: 2, speed: 60);
    }
    _effects.update(dt);
    _repaint.value++;

    if (_game.isOver && !_finishing) {
      _finishing = true;
      host.audio.ambientOn = false;
      // Let the final hit land visually, then hand the result to the platform.
      _finishTimer = Timer(const Duration(milliseconds: 1300), () {
        host.onFinished(RunResult(
          gameId: wizardShooter.id,
          runId: host.runId,
          score: _game.score,
          duration: Duration(milliseconds: (_game.elapsed * 1000).round()),
          stats: {'Enemies defeated': _game.enemiesDefeated, 'Spells cast': _game.castsMade},
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tracking = host.tracking;
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(builder: (context, constraints) {
        _size = constraints.biggest;
        return Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: WizardPainter(_scene, repaint: _repaint)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 30,
            child: Center(
              child: ValueListenableBuilder<int>(
                valueListenable: _repaint,
                builder: (_, _, _) => SpellBar(
                  game: _game,
                  switchProgress: _spellSwitch.progress,
                  onSelect: (id) {
                    if (_game.selectSpell(id)) _gesture.reset();
                  },
                ),
              ),
            ),
          ),
          Positioned(right: 16, top: 76, child: CameraStreamIndicator(tracking: tracking)),
          // Small camera inset (bottom-right) so the player can see their hand in frame.
          ListenableBuilder(
            listenable: Listenable.merge([tracking, host.settings, host.handInput]),
            builder: (context, _) {
              final show = host.settings.showCameraInset && !host.handInput.useSimulated && tracking.hasFrame;
              if (!show) return const SizedBox.shrink();
              return Positioned(
                right: 16,
                bottom: 16,
                width: 140,
                height: 210,
                child: IgnorePointer(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(border: Border.all(color: const Color(0x88FFD27A)), borderRadius: BorderRadius.circular(12)),
                      child: Opacity(opacity: 0.85, child: CameraPreview(controller: tracking)),
                    ),
                  ),
                ),
              );
            },
          ),
        ]);
      }),
    );
  }
}

/// Selected spell, lock state and cooldown; click a card to select it. Hand users switch with a
/// held ✌ (progress ring on the next spell), keyboard users with Q/Tab.
class SpellBar extends StatelessWidget {
  const SpellBar({super.key, required this.game, required this.onSelect, this.switchProgress = 0});
  final WizardGame game;
  final ValueChanged<String> onSelect;
  final double switchProgress;

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[];
    for (final id in SpellIds.all) {
      final unlocked = game.unlockedSpells.contains(id);
      final selected = game.selectedSpell == id;
      final color = spellColor(id);
      final cooldown = game.cooldownRemaining(id);
      cards.add(GestureDetector(
        onTap: unlocked ? () => onSelect(id) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC120B26),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? color : const Color(0x55B9A8D6), width: selected ? 2 : 1),
            boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 14)] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Stack(alignment: Alignment.center, children: [
                if (cooldown > 0) CircularProgressIndicator(value: 1 - cooldown, strokeWidth: 2, color: color),
                if (!selected && unlocked && switchProgress > 0) CircularProgressIndicator(value: switchProgress, strokeWidth: 2, color: Colors.white),
                Icon(
                  unlocked ? (id == SpellIds.chainLightning ? Icons.bolt : Icons.local_fire_department) : Icons.lock,
                  size: 16,
                  color: unlocked ? color : const Color(0xFF8A84A0),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Text(
              unlocked ? WizardEffects.spellName(id) : '${WizardEffects.spellName(id)} · reach ${game.config.chainLightning.unlockScore} in a run',
              style: TextStyle(fontFamily: 'Georgia', fontSize: 13, fontWeight: FontWeight.w700, color: unlocked ? (selected ? color : Colors.white70) : const Color(0xFF8A84A0)),
            ),
          ]),
        ),
      ));
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: cards),
      if (game.availableSpells.length > 1)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Switch: hold a V sign (two fingers up) · Q · click', style: TextStyle(fontFamily: 'Georgia', fontSize: 11, color: Colors.white54)),
        ),
    ]);
  }
}
