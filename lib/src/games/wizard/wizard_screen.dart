import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../app/app_settings.dart';
import '../../app/tracking_controller.dart';
import '../../audio/audio_service.dart';
import '../../input/hand_input_hub.dart';
import '../../platform/minigame.dart';
import '../../ui/camera_preview.dart';
import '../../ui/camera_stream_indicator.dart';
import 'day_night.dart';
import 'view/effects.dart';
import 'view/wizard_painter.dart';
import 'wizard_config.dart';
import 'wizard_game.dart';
import 'wizard_session.dart';

const wizardShooter = MinigameDefinition(
  id: 'wizard_shooter',
  title: "Wizard's Stand",
  tagline: 'Hold the line against the horde with fire (and lightning) from your fingertips.',
  builder: _build,
);

Widget _build(BuildContext context, MinigameHost host) => WizardGameScreen(host: host);

/// Hosts one run: drives a [WizardSession] (game + gestures + effects + audio) from a ticker and
/// handles what only a real run does: persisting the boss-defeat unlock, day/night/boss music,
/// and reporting the result. Leaving this widget (results screen, Esc) disposes the ticker, so
/// nothing keeps running in the background.
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
  late final WizardSession _session = WizardSession(host: host, game: _game);
  final ValueNotifier<int> _repaint = ValueNotifier(0);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  bool _finishing = false;
  Timer? _finishTimer;

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
    host.audio.ambientOn = true;
    host.audio.setMusic(MusicTracks.day);
    host.audio.play(Sounds.gameStart, positional: false);
    _session.onHand();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _finishTimer?.cancel();
    host.handInput.removeListener(_session.onHand);
    HardwareKeyboard.instance.removeHandler(_session.handleKey);
    host.handInput.simulated.setBlock(false);
    _repaint.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.0 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final events = _session.tick(dt);
    for (final e in events) {
      switch (e) {
        case SpellUnlocked(:final spellId):
          host.progression.unlock(spellId); // persisted once (Progression ignores repeats)
        case PhaseChanged(:final phase):
          host.audio.setMusic(phase == DayPhase.night ? MusicTracks.night : MusicTracks.day);
        default:
          break;
      }
    }
    _repaint.value++;

    if (_game.isOver && !_finishing) {
      _finishing = true;
      host.audio.ambientOn = false;
      host.audio.setMusic(null);
      // Let the final hit land visually, then hand the result to the platform.
      _finishTimer = Timer(const Duration(milliseconds: 1300), () {
        host.onFinished(RunResult(
          gameId: wizardShooter.id,
          runId: host.runId,
          score: _game.score,
          duration: Duration(milliseconds: (_game.elapsed * 1000).round()),
          stats: {
            'Enemies defeated': _game.enemiesDefeated,
            'Spells cast': _game.castsMade,
            if (_game.bossesDefeated > 0) 'Bosses defeated': _game.bossesDefeated,
          },
        ));
      });
    }
  }

  @override
  Widget build(BuildContext context) => WizardStage(
        session: _session,
        repaint: _repaint,
        tracking: host.tracking,
        settings: host.settings,
        handInput: host.handInput,
      );
}

/// The in-game view: the painted arena + HUD, the spell bar, the camera-stream indicator and
/// the small camera inset. Shared by the run screen and the tutorial.
class WizardStage extends StatelessWidget {
  const WizardStage({super.key, required this.session, required this.repaint, required this.tracking, required this.settings, required this.handInput, this.showSpellBar = true, this.showStreamIndicator = true});
  final WizardSession session;
  final ValueNotifier<int> repaint;
  final TrackingController tracking;
  final AppSettings settings;
  final HandInputHub handInput;
  final bool showSpellBar;

  /// Off where the app shell already shows the camera-stream indicator (the tutorial).
  final bool showStreamIndicator;

  @override
  Widget build(BuildContext context) {
    final game = session.game;
    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(builder: (context, constraints) {
        session.size = constraints.biggest;
        return Stack(fit: StackFit.expand, children: [
          CustomPaint(painter: WizardPainter(session.scene, repaint: repaint)),
          if (showSpellBar)
            Positioned(
              left: 0,
              right: 0,
              bottom: 30,
              child: Center(
                child: ValueListenableBuilder<int>(
                  valueListenable: repaint,
                  builder: (_, _, _) => SpellBar(game: game, switchProgress: session.spellSwitch.progress, onSelect: session.selectSpell),
                ),
              ),
            ),
          if (showStreamIndicator) Positioned(right: 16, top: 76, child: CameraStreamIndicator(tracking: tracking)),
          // Small camera inset (bottom-right) so the player can see their hand in frame.
          ListenableBuilder(
            listenable: Listenable.merge([tracking, settings, handInput]),
            builder: (context, _) {
              final show = settings.showCameraInset && cameraFeedState(tracking, simulated: handInput.useSimulated) != CameraFeedState.hidden;
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
                      child: Opacity(opacity: 0.85, child: CameraFeedView(controller: tracking, simulated: handInput.useSimulated)),
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
              unlocked ? WizardEffects.spellName(id) : '${WizardEffects.spellName(id)} · defeat a night boss',
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
