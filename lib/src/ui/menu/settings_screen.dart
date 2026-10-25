import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../app/app_settings.dart';
import '../../audio/audio_service.dart';
import '../../games/wizard/wizard_config.dart';
import '../../input/head_pose.dart';
import 'fantasy_theme.dart';

/// Preferences. Every change applies immediately and is saved locally. Permanent progression
/// (spell unlocks) is stored separately and is not affected by "Reset settings".
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final settings = s.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, s.audio, s.progression, s.tracking]),
      builder: (context, _) => SizedBox.expand(
        child: FantasyBackground(
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  FantasyButton(label: 'Back', icon: Icons.arrow_back, compact: true, onPressed: s.navigator.openStartMenu),
                  const SizedBox(width: 20),
                  Text('SETTINGS', style: Fantasy.title(34)),
                ]),
                const SizedBox(height: 20),
                Wrap(spacing: 20, runSpacing: 20, children: [
                  _panel(_HeadSection(services: s)),
                  _panel(_AudioSection(services: s)),
                  _panel(_MenuSection(services: s)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(Widget child) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560, minWidth: 380), child: FantasyPanel(child: child));
}

/// Slider + dwell-friendly −/+ buttons (sliders are hard to drag by hand-hover).
class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, required this.value, required this.min, required this.max, required this.step, required this.format, required this.onChanged});

  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final String Function(double) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(label, style: Fantasy.body)),
            Text(format(value), style: Fantasy.body.copyWith(color: Fantasy.gold, fontWeight: FontWeight.w700)),
          ]),
          Row(children: [
            FantasyButton(label: '−', compact: true, onPressed: value > min + 1e-9 ? () => onChanged((value - step).clamp(min, max)) : null),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(activeTrackColor: Fantasy.gold, thumbColor: Fantasy.gold, inactiveTrackColor: Fantasy.mist.withValues(alpha: 0.3)),
                child: Slider(value: value.clamp(min, max), min: min, max: max, divisions: ((max - min) / step).round(), onChanged: onChanged),
              ),
            ),
            FantasyButton(label: '+', compact: true, onPressed: value < max - 1e-9 ? () => onChanged((value + step).clamp(min, max)) : null),
          ]),
        ]),
      );
}

class _HeadSection extends StatelessWidget {
  const _HeadSection({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final settings = services.settings;
    final motion = services.tracking.companionStatus['motion'];
    final status = services.headInput.status;
    final statusText = settings.simulatedInput
        ? 'Simulated head (dev): arrow keys in game'
        : switch (status) {
            HeadTrackingStatus.tracking => 'Glasses head tracking active',
            HeadTrackingStatus.lost => 'Head tracking re-acquiring…',
            HeadTrackingStatus.unavailable => 'No head tracking source${motion != null ? ' (glasses motion: $motion)' : ''}. The game aims with your hand only.',
          };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('HEAD MOVEMENT', style: Fantasy.label),
      const SizedBox(height: 10),
      _Stepper(
        label: 'Head movement sensitivity',
        value: settings.headSensitivity,
        min: AppSettings.minHeadSensitivity,
        max: AppSettings.maxHeadSensitivity,
        step: 0.1,
        format: (v) => v == 0 ? 'Off' : '${v.toStringAsFixed(1)}×${v == AppSettings.defaultHeadSensitivity ? ' (default)' : ''}',
        onChanged: (v) => settings.headSensitivity = v,
      ),
      Text('How much turning your head turns the view and aim. 1.0× = one-to-one; 0 = off.', style: Fantasy.body.copyWith(fontSize: 13, color: Fantasy.mist)),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Text('Invert head direction', style: Fantasy.body)),
        FantasyChoice<bool>(options: const {false: 'Normal', true: 'Inverted'}, selected: settings.invertHeadYaw, onSelected: (v) => settings.invertHeadYaw = v),
      ]),
      const SizedBox(height: 8),
      Text(statusText, style: Fantasy.body.copyWith(fontSize: 13)),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerLeft, child: FantasyButton(label: 'Recenter head', icon: Icons.center_focus_strong, compact: true, onPressed: services.headInput.recenter)),
    ]);
  }
}

class _AudioSection extends StatelessWidget {
  const _AudioSection({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final settings = services.settings;
    final audio = services.audio;
    final route = audio.route;
    final options = <String, String>{
      AudioOutputChoice.auto: 'Auto (glasses if connected to this Mac)',
      AudioOutputChoice.system: 'Mac system default',
      AudioOutputChoice.companion: 'Glasses via iPhone companion',
      for (final d in audio.outputDevices) d['uid'] as String: '${d['name']}${d['bluetooth'] == true ? ' (Bluetooth)' : ''}',
    };
    final routeLine = switch (route['kind']) {
      'companion' => 'Playing on the iPhone (its current route; the glasses when they are its Bluetooth audio).',
      'device' => 'Playing on ${route['name']}.',
      'mac' => 'Playing on ${route['name']}.',
      'fallback' => 'Playing on ${route['name']}. ${route['note'] ?? ''}',
      _ => 'Starting audio…',
    };
    String pct(double v) => '${(v * 100).round()}%';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('AUDIO', style: Fantasy.label),
      const SizedBox(height: 10),
      _Stepper(label: 'Sound effects volume', value: settings.sfxVolume, min: 0, max: 1, step: 0.05, format: pct, onChanged: (v) => settings.sfxVolume = v),
      _Stepper(label: 'Ambient volume', value: settings.ambientVolume, min: 0, max: 1, step: 0.05, format: pct, onChanged: (v) => settings.ambientVolume = v),
      Text('Positional sound', style: Fantasy.body),
      const SizedBox(height: 6),
      FantasyChoice<SpatialMode>(
        options: const {SpatialMode.stereo: 'Stereo panning (speakers, glasses)', SpatialMode.binaural: 'Binaural 3D (headphones)'},
        selected: settings.spatialMode,
        onSelected: (m) => settings.spatialMode = m,
      ),
      const SizedBox(height: 14),
      Text('Output', style: Fantasy.body),
      const SizedBox(height: 6),
      FantasyChoice<String>(options: options, selected: options.containsKey(settings.audioOutput) ? settings.audioOutput : AudioOutputChoice.auto, onSelected: (v) => settings.audioOutput = v),
      const SizedBox(height: 8),
      Text(routeLine, style: Fantasy.body.copyWith(fontSize: 13)),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FantasyButton(label: 'Test: left', icon: Icons.volume_up, compact: true, onPressed: () => audio.play(Sounds.zap, x: -6, z: 4)),
        FantasyButton(label: 'Test: right', icon: Icons.volume_up, compact: true, onPressed: () => audio.play(Sounds.zap, x: 6, z: 4)),
        FantasyButton(label: 'Test: far ahead', icon: Icons.volume_down, compact: true, onPressed: () => audio.play(Sounds.zap, x: 0, z: 26)),
      ]),
    ]);
  }
}

class _MenuSection extends StatelessWidget {
  const _MenuSection({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final settings = services.settings;
    final lightning = services.progression.isUnlocked(SpellIds.chainLightning);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('MENUS & DISPLAY', style: Fantasy.label),
      const SizedBox(height: 10),
      _Stepper(
        label: 'Hand hover-to-select time',
        value: settings.dwellSeconds,
        min: AppSettings.minDwellSeconds,
        max: AppSettings.maxDwellSeconds,
        step: 0.1,
        format: (v) => '${v.toStringAsFixed(1)} s',
        onChanged: (v) => settings.dwellSeconds = v,
      ),
      Row(children: [
        Expanded(child: Text('Camera view in game', style: Fantasy.body)),
        FantasyChoice<bool>(options: const {true: 'Show', false: 'Hide'}, selected: settings.showCameraInset, onSelected: (v) => settings.showCameraInset = v),
      ]),
      const SizedBox(height: 18),
      Text('PROGRESSION', style: Fantasy.label),
      const SizedBox(height: 8),
      Text(
        lightning
            ? 'Chain Lightning: unlocked (permanent)'
            : 'Chain Lightning: locked — score ${const ChainLightningSpec().unlockScore} in a single run to unlock it forever.',
        style: Fantasy.body.copyWith(color: lightning ? Fantasy.ok : Fantasy.parchment),
      ),
      const SizedBox(height: 18),
      Align(
        alignment: Alignment.centerLeft,
        child: FantasyButton(label: 'Reset settings to defaults', icon: Icons.restart_alt, compact: true, onPressed: settings.resetToDefaults),
      ),
      const SizedBox(height: 6),
      Text('Resetting settings never removes unlocked spells or high scores.', style: Fantasy.body.copyWith(fontSize: 12, color: Fantasy.mist)),
    ]);
  }
}
