import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../platform/minigame.dart';
import '../../ui/camera_preview.dart';
import 'cast_gesture.dart';
import 'view/effects.dart';
import 'view/wizard_painter.dart';
import 'wizard_config.dart';
import 'wizard_game.dart';

const wizardShooter = MinigameDefinition(
  id: 'wizard_shooter',
  title: "Wizard's Stand",
  tagline: 'Hold the line against the horde with fire from your fingertips.',
  builder: _build,
);

Widget _build(BuildContext context, MinigameHost host) => WizardGameScreen(host: host);

/// Hosts one run: drives [WizardGame] from a ticker, turns hand input into casts through
/// [CastGestureRecognizer], and renders with [WizardPainter]. Leaving this widget (results
/// screen, Esc) disposes the ticker, so nothing keeps running in the background.
class WizardGameScreen extends StatefulWidget {
  const WizardGameScreen({super.key, required this.host, this.seed, this.config = const WizardConfig()});
  final MinigameHost host;
  final int? seed;
  final WizardConfig config;

  @override
  State<WizardGameScreen> createState() => WizardGameScreenState();
}

class WizardGameScreenState extends State<WizardGameScreen> with SingleTickerProviderStateMixin {
  late final WizardGame _game = WizardGame(seed: widget.seed, config: widget.config);

  @visibleForTesting
  WizardGame get game => _game;
  final CastGestureRecognizer _gesture = CastGestureRecognizer();
  final WizardEffects _effects = WizardEffects();
  late final WizardSceneState _scene = WizardSceneState(game: _game, effects: _effects);
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _finishing = false;
  Timer? _finishTimer;

  MinigameHost get host => widget.host;

  @override
  void initState() {
    super.initState();
    host.handInput.addListener(_onHand);
    _onHand();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _finishTimer?.cancel();
    host.handInput.removeListener(_onHand);
    _repaint.dispose();
    super.dispose();
  }

  void _onHand() {
    final frame = host.handInput.value;
    _scene.hand = frame;
    _scene.simulated = frame.simulated;
    if (_gesture.update(frame)) {
      final result = _game.castFireball();
      _effects.onCast();
      debugPrint('[metarayzer] fireball cast: ${result.name} (score ${_game.score}, lives ${_game.lives})');
    }
    _scene.gesture = _gesture.feedback;
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    _scene.time += dt;
    _game.update(dt);
    _gesture.tick();
    _scene.gesture = _gesture.feedback;
    _effects.consume(_game.drainEvents());
    _effects.update(dt);
    _repaint.value++;

    if (_game.isOver && !_finishing) {
      _finishing = true;
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
      child: Stack(fit: StackFit.expand, children: [
        CustomPaint(painter: WizardPainter(_scene, repaint: _repaint)),
        // Small camera inset (bottom-right) so the player can see their hand in frame.
        ListenableBuilder(
          listenable: Listenable.merge([tracking, host.settings, host.handInput]),
          builder: (context, _) {
            final show = host.settings.showCameraInset && !host.handInput.useSimulated && tracking.hasFrame;
            if (!show) return const SizedBox.shrink();
            return Positioned(
              right: 16,
              bottom: 16,
              width: 150,
              height: 220,
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
      ]),
    );
  }
}
