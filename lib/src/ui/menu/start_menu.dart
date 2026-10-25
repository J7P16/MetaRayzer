import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../../app/app_services.dart';
import '../../app/app_settings.dart';
import '../../input/hand_input.dart';
import 'fantasy_theme.dart';

class StartMenu extends StatelessWidget {
  const StartMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final game = s.navigator.games.first;
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.tracking, s.handInput, s.leaderboards[game.id]!]),
      builder: (context, _) => SizedBox.expand(
        child: FantasyBackground(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth > 980;
                final left = _TitleColumn(onPlay: s.navigator.playDefault, tagline: game.tagline);
                final right = _SidePanels(services: s, gameId: game.id);
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 5, child: left),
                            const SizedBox(width: 32),
                            Expanded(flex: 4, child: right),
                          ],
                        )
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 24), right]),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleColumn extends StatelessWidget {
  const _TitleColumn({required this.onPlay, required this.tagline});
  final VoidCallback onPlay;
  final String tagline;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 24),
      Text('METARAYZER PRESENTS', style: Fantasy.label),
      const SizedBox(height: 8),
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text("WIZARD'S\nSTAND", style: Fantasy.title(72).copyWith(height: 1.0)),
      ),
      const SizedBox(height: 12),
      Text(tagline, style: Fantasy.body.copyWith(fontSize: 18, color: Fantasy.mist)),
      const SizedBox(height: 36),
      FantasyButton(label: 'PLAY', icon: Icons.local_fire_department, primary: true, onPressed: onPlay),
      const SizedBox(height: 36),
      FantasyPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('HOW TO CAST', style: Fantasy.label),
            const SizedBox(height: 10),
            const _Step(icon: Icons.back_hand_outlined, text: 'Raise your LEFT hand into the glasses\' view, fingers pointing up.'),
            const _Step(icon: Icons.sports_mma, text: 'Close it into a FIST: your spell is ready.'),
            const _Step(icon: Icons.front_hand, text: 'Snap it OPEN: a fireball strikes the nearest enemy inside the rune line.'),
            const _Step(icon: Icons.replay, text: 'Close your fist again to ready the next spell. Three hits and you fall.'),
          ],
        ),
      ),
    ],
  );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Fantasy.ember, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: Fantasy.body)),
      ],
    ),
  );
}

class _SidePanels extends StatelessWidget {
  const _SidePanels({required this.services, required this.gameId});
  final AppServices services;
  final String gameId;

  @override
  Widget build(BuildContext context) {
    final settings = services.settings;
    final scores = services.leaderboards[gameId]!.top.map((e) => e.score).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FantasyPanel(child: _StatusBlock(services: services)),
        const SizedBox(height: 16),
        FantasyPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('MENU CONTROL', style: Fantasy.label),
              const SizedBox(height: 8),
              FantasyChoice<UiControlMode>(
                options: const {UiControlMode.mouse: 'Mouse & keyboard', UiControlMode.hand: 'Hand (hover to select)'},
                selected: settings.uiControlMode,
                onSelected: (m) => settings.uiControlMode = m,
              ),
              if (settings.uiControlMode == UiControlMode.hand) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('Hover time', style: Fantasy.body),
                    const Spacer(),
                    FantasyButton(label: '−', compact: true, onPressed: () => settings.dwellSeconds -= 0.2),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Text('${settings.dwellSeconds.toStringAsFixed(1)} s', style: Fantasy.body),
                    ),
                    FantasyButton(label: '+', compact: true, onPressed: () => settings.dwellSeconds += 0.2),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('CASTING HAND', style: Fantasy.label),
              const SizedBox(height: 8),
              FantasyChoice<HandPreference>(
                options: const {HandPreference.left: 'Left', HandPreference.right: 'Right', HandPreference.any: 'Either'},
                selected: settings.handPreference,
                onSelected: (p) => settings.handPreference = p,
              ),
          const SizedBox(height: 16),
          Text('CAMERA VIEW IN GAME', style: Fantasy.label),
          const SizedBox(height: 8),
          FantasyChoice<bool>(
            options: const {true: 'Show small inset', false: 'Hide'},
            selected: settings.showCameraInset,
            onSelected: (v) => settings.showCameraInset = v,
          ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FantasyPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('HALL OF FLAME · TOP 3', style: Fantasy.label),
              const SizedBox(height: 10),
              LeaderboardList(scores: scores),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusBlock extends StatelessWidget {
  const _StatusBlock({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final t = services.tracking;
    final settings = services.settings;
    final hand = services.handInput.value;
    final streaming = t.companionStatus['stream'] == 'streaming';

    final (glassesText, glassesColor) = switch (t.source) {
      FrameSource.webcam => ('Using the Mac webcam (dev fallback), not the glasses', Fantasy.warn),
      _ when !t.companionConnected => ('Glasses not connected: open MetaRayzer Companion on your iPhone', Fantasy.bad),
      _ when streaming => ('Glasses connected · camera streaming${t.companionStatus['mock'] == true ? ' (MOCK)' : ''}', Fantasy.ok),
      _ => ('iPhone connected · glasses camera not streaming', Fantasy.warn),
    };
    final (handText, handColor) = settings.simulatedHand
        ? ('Simulated hand (dev): mouse = hand, hold button or Space = fist', Fantasy.warn)
        : switch (hand.status) {
            HandTrackingStatus.tracking => ('Hand detected · ${hand.pose.name}', Fantasy.ok),
            HandTrackingStatus.searching => ('Hand detection ready · raise your hand into view', Fantasy.ok),
            HandTrackingStatus.lost => ('Hand briefly lost', Fantasy.warn),
            HandTrackingStatus.unavailable => ('Hand detection unavailable · ${hand.message ?? ''}', Fantasy.bad),
          };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('THE SEEING STONES', style: Fantasy.label),
        const SizedBox(height: 10),
        _StatusLine(icon: Icons.visibility, color: glassesColor, text: glassesText),
        _StatusLine(icon: Icons.back_hand, color: handColor, text: handText),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (t.source == FrameSource.companion && t.companionConnected && !streaming)
              FantasyButton(label: 'Start glasses camera', icon: Icons.videocam, compact: true, onPressed: t.startGlassesStream),
            FantasyButton(label: 'Glasses & tracking setup', icon: Icons.tune, compact: true, onPressed: services.navigator.openSetup),
            FantasyButton(
              label: settings.simulatedHand ? 'Use camera hand' : 'Simulated hand (dev)',
              icon: settings.simulatedHand ? Icons.videocam : Icons.mouse,
              compact: true,
              onPressed: () => settings.simulatedHand = !settings.simulatedHand,
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Fantasy.body.copyWith(fontSize: 14))),
      ],
    ),
  );
}
