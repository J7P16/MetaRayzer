import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../../app/app_services.dart';
import '../../games/wizard/wizard_config.dart';
import '../../input/hand_input.dart';
import 'fantasy_theme.dart';

class StartMenu extends StatelessWidget {
  const StartMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final game = s.navigator.games.first;
    return ListenableBuilder(
      listenable: Listenable.merge([s.settings, s.tracking, s.handInput, s.progression, s.leaderboards[game.id]!]),
      builder: (context, _) => SizedBox.expand(
        child: FantasyBackground(
          child: SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth > 980;
              final left = _TitleColumn(services: s, tagline: game.tagline);
              final right = _SidePanels(services: s, gameId: game.id);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: wide
                    ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(flex: 5, child: left),
                        const SizedBox(width: 32),
                        Expanded(flex: 4, child: right),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [left, const SizedBox(height: 24), right]),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _TitleColumn extends StatelessWidget {
  const _TitleColumn({required this.services, required this.tagline});
  final AppServices services;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final lightning = services.progression.isUnlocked(SpellIds.chainLightning);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 24),
      Text('METARAYZER PRESENTS', style: Fantasy.label),
      const SizedBox(height: 8),
      FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text("WIZARD'S\nSTAND", style: Fantasy.title(72).copyWith(height: 1.0))),
      const SizedBox(height: 12),
      Text(tagline, style: Fantasy.body.copyWith(fontSize: 18, color: Fantasy.mist)),
      const SizedBox(height: 32),
      Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FantasyButton(label: 'PLAY', icon: Icons.local_fire_department, primary: true, onPressed: services.navigator.playDefault),
        FantasyButton(label: 'Tutorial', icon: Icons.school_outlined, onPressed: services.navigator.openTutorial),
        FantasyButton(label: 'Settings', icon: Icons.tune, onPressed: services.navigator.openSettings),
      ]),
      const SizedBox(height: 10),
      Text('Navigate with the mouse, or hover your hand over a button until its ring fills.', style: Fantasy.body.copyWith(fontSize: 13, color: Fantasy.mist)),
      const SizedBox(height: 28),
      FantasyPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('HOW TO CAST · LEFT HAND', style: Fantasy.label),
          const SizedBox(height: 10),
          const _Step(icon: Icons.back_hand_outlined, text: "Raise your LEFT hand into the glasses' view, fingers pointing up. Your staff follows it."),
          const _Step(icon: Icons.sports_mma, text: 'Close it into a FIST: your spell is ready.'),
          const _Step(icon: Icons.front_hand, text: 'Snap it OPEN to cast. Close your fist again before the next spell.'),
          const _Step(icon: Icons.shield_outlined, text: 'SHIELD: hold up one finger (index up, other fingers curled). It blocks arrows and bolts for 0.5 s; relax the finger to use it again.'),
          _Step(
            icon: Icons.bolt,
            text: lightning
                ? 'Hold a V sign (two fingers up) or press Q to switch between Fireball and Chain Lightning.'
                : 'Survive the day and defeat the night boss to unlock Chain Lightning forever.',
          ),
        ]),
      ),
      const SizedBox(height: 16),
      FantasyPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SPELLBOOK', style: Fantasy.label),
          const SizedBox(height: 10),
          const _Spell(icon: Icons.local_fire_department, color: Fantasy.ember, name: 'Fireball', text: 'Homes in on the nearest enemy inside the rune line.', unlocked: true),
          const _Spell(icon: Icons.shield_outlined, color: Color(0xFF6CF2FF), name: 'Shield', text: 'Always ready, whatever spell is selected. Blocks projectiles only, never melee blows.', unlocked: true),
          _Spell(
            icon: Icons.bolt,
            color: const Color(0xFF7FE7FF),
            name: 'Chain Lightning',
            text: 'Strikes the first enemy where your staff points, then arcs to nearby enemies with weaker jolts.${lightning ? '' : ' Unlocked by defeating your first night boss.'}',
            unlocked: lightning,
          ),
        ]),
      ),
    ]);
  }
}

class _Spell extends StatelessWidget {
  const _Spell({required this.icon, required this.color, required this.name, required this.text, required this.unlocked});
  final IconData icon;
  final Color color;
  final String name;
  final String text;
  final bool unlocked;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(unlocked ? icon : Icons.lock, color: unlocked ? color : Fantasy.mist, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$name${unlocked ? '' : ' (locked)'}  ', style: Fantasy.body.copyWith(color: unlocked ? color : Fantasy.mist, fontWeight: FontWeight.w700)),
              TextSpan(text: text, style: Fantasy.body),
            ])),
          ),
        ]),
      );
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: Fantasy.ember, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Fantasy.body)),
        ]),
      );
}

class _SidePanels extends StatelessWidget {
  const _SidePanels({required this.services, required this.gameId});
  final AppServices services;
  final String gameId;

  @override
  Widget build(BuildContext context) {
    final scores = services.leaderboards[gameId]!.top.map((e) => e.score).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 30),
      FantasyPanel(child: _StatusBlock(services: services)),
      const SizedBox(height: 16),
      FantasyPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('HALL OF FLAME · TOP 3', style: Fantasy.label),
          const SizedBox(height: 10),
          LeaderboardList(scores: scores),
        ]),
      ),
    ]);
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
    final (handText, handColor) = settings.simulatedInput
        ? ('Simulated input (dev): mouse = hand, hold button or Space = fist', Fantasy.warn)
        : switch (hand.status) {
            HandTrackingStatus.tracking => ('Left hand detected · ${hand.pose.name}', Fantasy.ok),
            HandTrackingStatus.searching => ('Hand detection ready · raise your left hand into view', Fantasy.ok),
            HandTrackingStatus.lost => ('Hand briefly lost', Fantasy.warn),
            HandTrackingStatus.unavailable => ('Hand detection unavailable · ${hand.message ?? ''}', Fantasy.bad),
          };

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('THE SEEING STONES', style: Fantasy.label),
      const SizedBox(height: 10),
      _StatusLine(icon: Icons.visibility, color: glassesColor, text: glassesText),
      _StatusLine(icon: Icons.back_hand, color: handColor, text: handText),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (t.source == FrameSource.companion && t.companionConnected && !streaming)
          FantasyButton(label: 'Start glasses camera', icon: Icons.videocam, compact: true, onPressed: t.startGlassesStream),
        FantasyButton(label: 'Glasses & tracking setup', icon: Icons.tune, compact: true, onPressed: services.navigator.openSetup),
        FantasyButton(
          label: settings.simulatedInput ? 'Use camera hand' : 'Simulated input (dev)',
          icon: settings.simulatedInput ? Icons.videocam : Icons.mouse,
          compact: true,
          onPressed: () => settings.simulatedInput = !settings.simulatedInput,
        ),
      ]),
    ]);
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
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: Fantasy.body.copyWith(fontSize: 14))),
        ]),
      );
}
