import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../../audio/audio_service.dart';
import '../../../input/hand_input.dart';
import '../../../input/head_pose.dart';
import '../../../platform/minigame.dart';
import '../../../ui/menu/fantasy_theme.dart';
import '../../../ui/menu_camera_backdrop.dart';
import '../cast_gesture.dart';
import '../wizard_config.dart';
import '../wizard_game.dart';
import '../wizard_screen.dart';
import '../wizard_session.dart';
import 'gesture_illustrations.dart';
import 'tutorial_flow.dart';

/// A short, replayable, hands-on tutorial: look around → cast at a practice target → time the
/// shield against a slow telegraphed arrow → done.
///
/// It runs a [WizardGame] in [GameMode.tutorial] through the same [WizardSession] the real game
/// uses (same gestures, aiming, rendering, sounds), so what the player practices is exactly the
/// real control scheme. Tutorial mode never spawns on its own, costs no lives, scores nothing
/// and never emits unlocks; this screen never touches progression or the leaderboard. Leaving it
/// disposes the sandbox, so practice enemies and projectiles can't leak into a run.
class WizardTutorialScreen extends StatefulWidget {
  const WizardTutorialScreen({super.key, required this.host, required this.onPlay, required this.onExit});
  final MinigameHost host;
  final VoidCallback onPlay;
  final VoidCallback onExit;

  @override
  State<WizardTutorialScreen> createState() => WizardTutorialScreenState();
}

class WizardTutorialScreenState extends State<WizardTutorialScreen> with SingleTickerProviderStateMixin {
  late final WizardGame _game = WizardGame(seed: 5, config: TutorialFlow.practiceConfig(), mode: GameMode.tutorial);
  late final WizardSession _session = WizardSession(host: widget.host, game: _game);
  final TutorialFlow flow = TutorialFlow();
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;

  /// Seconds left of the "success" celebration before moving on automatically.
  double _advanceIn = 0;
  bool _celebrated = false;

  MinigameHost get host => widget.host;

  @visibleForTesting
  WizardGame get game => _game;

  @visibleForTesting
  WizardSession get session => _session;

  @override
  void initState() {
    super.initState();
    host.handInput.addListener(_session.onHand);
    host.headInput.simulated = host.settings.simulatedInput;
    HardwareKeyboard.instance.addHandler(_session.handleKey);
    _enterStep();
    _session.onHand();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    host.handInput.removeListener(_session.onHand);
    HardwareKeyboard.instance.removeHandler(_session.handleKey);
    host.handInput.simulated.setBlock(false);
    _repaint.dispose();
    super.dispose();
  }

  /// Resets the sandbox for the current step: only that step's practice actors exist.
  void _enterStep() {
    _game.enemies.clear();
    _game.projectiles.clear();
    _game.fireballs.clear();
    _game.drainEvents();
    _session.gesture.reset();
    _session.shieldGesture.reset();
    _game.shield.reset();
    _celebrated = false;
    _advanceIn = 0;
    _session.castingEnabled = flow.step == TutorialStep.cast;
    _session.scene
      ..showShieldHud = flow.step == TutorialStep.shield
      ..showRunHud = false
      ..bannerTop = 70;
    switch (flow.step) {
      case TutorialStep.cast:
        _game.spawn(EnemyKind.troll, x: 0).z = 9;
      case TutorialStep.shield:
        _game.spawn(EnemyKind.skeletonArcher, x: 1.5).z = 13.9;
      case TutorialStep.look || TutorialStep.done:
        break;
    }
  }

  void _next() => setState(() {
        flow.next();
        _enterStep();
      });

  void _skip() => setState(() {
        flow.skip();
        _enterStep();
      });

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final events = _session.tick(dt);
    final before = flow.lastAttempt;
    flow.onHead(_session.scene.head);
    flow.onEvents(events, _game.elapsed);
    // Keep the practice target available until it is hit.
    if (flow.step == TutorialStep.cast && !flow.castHit && _game.livingEnemies.isEmpty) _game.spawn(EnemyKind.troll, x: 0).z = 9;
    if (flow.stepComplete && !_celebrated && flow.step != TutorialStep.done) {
      _celebrated = true;
      _advanceIn = 1.8;
      host.audio.play(Sounds.tutorialSuccess, positional: false);
    }
    if (_advanceIn > 0) {
      _advanceIn -= dt;
      if (_advanceIn <= 0) _next();
    }
    if (before != flow.lastAttempt || flow.step == TutorialStep.look || _celebrated) setState(() {});
    _repaint.value++;
  }

  @override
  Widget build(BuildContext context) {
    final practice = flow.step == TutorialStep.cast || flow.step == TutorialStep.shield;
    return Stack(fit: StackFit.expand, children: [
      if (practice)
        WizardStage(session: _session, repaint: _repaint, tracking: host.tracking, settings: host.settings, handInput: host.handInput, showSpellBar: false, showStreamIndicator: false)
      else
        const _CameraBackground(),
      Positioned(left: 24, top: 16, child: _TopBar(flow: flow, onSkip: flow.step == TutorialStep.done ? null : _skip, onExit: widget.onExit)),
      if (flow.step != TutorialStep.done)
        Positioned(left: 24, top: 84, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: _instructionCard()))
      else
        Center(child: _doneCard()),
      if (_celebrated && flow.step != TutorialStep.done) const IgnorePointer(child: Center(child: _SuccessBadge())),
    ]);
  }

  Widget _instructionCard() {
    final (GestureKind kind, String title, String text) = switch (flow.step) {
      TutorialStep.look => (GestureKind.look, 'LOOK AROUND', "This is your glasses' view. Turn your head left and right: the arena turns with you."),
      TutorialStep.cast => (GestureKind.cast, 'CAST A FIREBALL', 'Left hand, fingers up. Make a FIST, then snap it OPEN.'),
      TutorialStep.shield => (GestureKind.shield, 'BLOCK THE ARROW', 'Raise your forearm upright in front of your face as the arrow arrives. The shield lasts 0.5 s and stops projectiles only.'),
      TutorialStep.done => (GestureKind.look, '', ''),
    };
    return FantasyPanel(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          GestureIllustration(kind: kind, size: 120),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Fantasy.label.copyWith(color: Fantasy.gold, fontSize: 13)),
              const SizedBox(height: 6),
              Text(text, style: Fantasy.body.copyWith(fontSize: 14)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        _detection(),
      ]),
    );
  }

  /// Live "did the game see it?" feedback for the current step.
  Widget _detection() {
    switch (flow.step) {
      case TutorialStep.look:
        final head = _session.scene.head;
        if (head.status == HeadTrackingStatus.unavailable) {
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Chip(text: 'Head tracking unavailable · the game aims with your hand only', ok: false),
            const SizedBox(height: 8),
            FantasyButton(label: 'Continue', icon: Icons.arrow_forward, compact: true, onPressed: _skip),
          ]);
        }
        return Wrap(spacing: 8, runSpacing: 8, children: [
          _Chip(text: '← Looked left', ok: flow.lookedLeft),
          _Chip(text: 'Looked right →', ok: flow.lookedRight),
          if (head.simulated) const _Chip(text: 'Simulated: arrow keys', ok: null),
        ]);
      case TutorialStep.cast:
        final g = _session.gesture.feedback;
        final hand = host.handInput.value;
        final text = switch (g.phase) {
          CastPhase.noHand => hand.status == HandTrackingStatus.unavailable ? 'No hand input: ${hand.message ?? 'camera off'}' : 'Raise your left hand into view',
          CastPhase.idle => 'Seen: ${hand.pose.name} · make a fist',
          CastPhase.ready => 'Fist seen · now snap it open!',
          CastPhase.charging => 'Opening…',
          CastPhase.spent => 'Cast! Close your fist to ready again',
        };
        return _Chip(text: flow.castHit ? 'Target hit!' : text, ok: flow.castHit ? true : (g.phase == CastPhase.ready ? null : false));
      case TutorialStep.shield:
        final held = _session.shieldGesture.held;
        final readiness = _session.shieldGesture.readiness;
        final feedback = switch (flow.lastAttempt) {
          ShieldAttempt.blocked => 'Blocked!',
          ShieldAttempt.tooEarly => 'Too early: the shield faded before the arrow arrived',
          ShieldAttempt.tooLate => 'Too late (or the pose was not recognized): raise it as the arrow comes close',
          ShieldAttempt.none => 'Watch the skeleton: it warns, then fires',
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text('Pose', style: Fantasy.body.copyWith(fontSize: 13)),
            const SizedBox(width: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(value: readiness, minHeight: 8, color: held ? const Color(0xFF6CF2FF) : Fantasy.gold, backgroundColor: const Color(0x33FFFFFF)),
              ),
            ),
            const SizedBox(width: 8),
            Text(held ? 'detected' : 'not yet', style: Fantasy.body.copyWith(fontSize: 13, color: held ? const Color(0xFF6CF2FF) : Fantasy.mist)),
          ]),
          const SizedBox(height: 8),
          _Chip(text: feedback, ok: flow.lastAttempt == ShieldAttempt.blocked ? true : (flow.lastAttempt == ShieldAttempt.none ? null : false)),
          if (host.settings.simulatedInput) ...[const SizedBox(height: 6), const _Chip(text: 'Simulated: hold B for the blocking pose', ok: null)],
        ]);
      case TutorialStep.done:
        return const SizedBox.shrink();
    }
  }

  Widget _doneCard() => ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: FantasyPanel(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text("YOU'RE READY", style: Fantasy.title(36)),
            const SizedBox(height: 14),
            Wrap(spacing: 10, runSpacing: 8, alignment: WrapAlignment.center, children: [
              for (final (step, label) in [(TutorialStep.look, 'Look around'), (TutorialStep.cast, 'Cast'), (TutorialStep.shield, 'Shield')])
                _Chip(text: label, ok: flow.skipped.contains(step) ? null : true),
            ]),
            const SizedBox(height: 14),
            Text('Survive the day, then defeat the night boss to unlock Chain Lightning forever.', textAlign: TextAlign.center, style: Fantasy.body),
            const SizedBox(height: 6),
            Text('Practice never changes your scores, unlocks or progress.', textAlign: TextAlign.center, style: Fantasy.body.copyWith(fontSize: 13, color: Fantasy.mist)),
            const SizedBox(height: 22),
            Wrap(spacing: 16, runSpacing: 12, alignment: WrapAlignment.center, children: [
              FantasyButton(label: 'PLAY', icon: Icons.local_fire_department, primary: true, onPressed: widget.onPlay),
              FantasyButton(label: 'START MENU', icon: Icons.home_outlined, onPressed: widget.onExit),
            ]),
          ]),
        ),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.flow, required this.onSkip, required this.onExit});
  final TutorialFlow flow;
  final VoidCallback? onSkip;
  final VoidCallback onExit;

  @override
  Widget build(BuildContext context) => Row(children: [
        DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xCC120B26), borderRadius: BorderRadius.circular(12), border: Border.all(color: Fantasy.goldDeep.withValues(alpha: 0.6))),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('TUTORIAL', style: Fantasy.label.copyWith(color: Fantasy.gold)),
              const SizedBox(width: 12),
              for (var i = 0; i < TutorialFlow.practiceSteps; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Icon(
                    i < flow.step.index ? Icons.check_circle : (i == flow.step.index ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    size: 16,
                    color: i <= flow.step.index ? Fantasy.gold : Fantasy.mist,
                  ),
                ),
            ]),
          ),
        ),
        // Next to the progress pill: the top-right corner belongs to the camera-stream indicator.
        const SizedBox(width: 12),
        if (onSkip != null) ...[FantasyButton(label: 'Skip step', icon: Icons.skip_next, compact: true, onPressed: onSkip), const SizedBox(width: 10)],
        FantasyButton(label: 'Exit tutorial', icon: Icons.close, compact: true, onPressed: onExit),
      ]);
}

/// Status chip: ok = true (done, ✓), false (not yet), null (neutral info).
class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.ok});
  final String text;
  final bool? ok;

  @override
  Widget build(BuildContext context) {
    final color = ok == true ? Fantasy.ok : (ok == false ? Fantasy.mist : Fantasy.warn);
    return DecoratedBox(
      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.7))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ok == true ? Icons.check : (ok == false ? Icons.radio_button_unchecked : Icons.info_outline), size: 14, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: Fantasy.body.copyWith(fontSize: 13, color: ok == true ? Fantasy.ok : Fantasy.parchment))),
        ]),
      ),
    );
  }
}

class _SuccessBadge extends StatelessWidget {
  const _SuccessBadge();

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1),
        duration: const Duration(milliseconds: 350),
        curve: Curves.elasticOut,
        builder: (_, v, child) => Transform.scale(scale: v, child: child),
        child: DecoratedBox(
          decoration: BoxDecoration(color: const Color(0xDD120B26), shape: BoxShape.circle, border: Border.all(color: Fantasy.ok, width: 3), boxShadow: const [BoxShadow(color: Color(0x887CE8A3), blurRadius: 40)]),
          child: const Padding(padding: EdgeInsets.all(26), child: Icon(Icons.check, size: 64, color: Fantasy.ok)),
        ),
      );
}

/// Step 1 and the summary: the live glasses view (same mapping as gameplay), or a clear
/// fallback when no stream is running.
class _CameraBackground extends StatelessWidget {
  const _CameraBackground();

  @override
  Widget build(BuildContext context) => const FantasyBackground(child: MenuCameraBackdrop(forceVisible: true, showFallback: true));
}
