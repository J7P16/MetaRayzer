import 'package:flutter/material.dart';
import 'package:metarayzer_native/metarayzer_native.dart';

import '../app/tracking_controller.dart';
import '../geometry/hand_geometry.dart';
import '../geometry/view_mapping.dart';
import '../tracking/hand_tracker.dart';
import 'hand_overlay_painter.dart';

/// Connection status, stream controls, display options and the debug readout.
class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section('Source', [
          SegmentedButton<FrameSource>(
            segments: const [
              ButtonSegment(value: FrameSource.companion, label: Text('Glasses (iPhone)'), icon: Icon(Icons.visibility_outlined)),
              ButtonSegment(value: FrameSource.webcam, label: Text('Mac webcam (dev)'), icon: Icon(Icons.laptop_mac)),
            ],
            selected: {c.source},
            onSelectionChanged: (s) => c.setSource(s.first),
          ),
        ]),
        if (c.source == FrameSource.companion) _linkSection(context),
        _Section('Display', [
          Row(children: [
            const Text('Fit'),
            const Spacer(),
            SegmentedButton<PreviewFit>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: PreviewFit.contain, label: Text('Contain')),
                ButtonSegment(value: PreviewFit.cover, label: Text('Cover')),
              ],
              selected: {c.fit},
              onSelectionChanged: (s) => c.update(fit: s.first),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Hand center'),
            const Spacer(),
            SegmentedButton<CenterMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: CenterMode.palmCentroid, label: Text('Palm')),
                ButtonSegment(value: CenterMode.boundingBox, label: Text('Box')),
              ],
              selected: {c.centerMode},
              onSelectionChanged: (s) => c.update(centerMode: s.first),
            ),
          ]),
          _Toggle('Mirror preview', c.mirrored, (v) => c.update(mirrored: v)),
          Row(children: [
            Text('Rotation: ${c.quarterTurns * 90}°'),
            const Spacer(),
            IconButton(tooltip: 'Rotate 90° clockwise', onPressed: () => c.update(quarterTurns: c.quarterTurns + 1), icon: const Icon(Icons.rotate_right)),
          ]),
          _Toggle('Hand detection', c.detectionEnabled, c.setDetectionEnabled),
          _Toggle('Show landmarks', c.showLandmarks, (v) => c.update(showLandmarks: v)),
          _Toggle('Debug info', c.showDebug, (v) => c.update(showDebug: v)),
        ]),
        if (c.showDebug) _debugSection(context),
      ],
    );
  }

  Widget _linkSection(BuildContext context) {
    final c = controller;
    final s = c.companionStatus;
    final info = c.serverInfo;
    final listening = c.server.state == 'listening';
    final streaming = s['stream'] == 'streaming';
    return _Section('Glasses link', [
      _StatusRow(
        'Mac listener',
        switch (c.server.state) {
          'listening' => 'Listening · ${info?.addresses.join(', ') ?? ''} : ${c.server.port}',
          'failed' => c.server.message ?? 'Failed',
          final other => other,
        },
        listening ? _Level.ok : (c.server.state == 'failed' ? _Level.error : _Level.pending),
      ),
      _StatusRow(
        'iPhone companion',
        c.companionConnected ? 'Connected · ${c.companion.deviceName ?? c.companion.address ?? ''}' : 'Not connected',
        c.companionConnected ? _Level.ok : _Level.pending,
      ),
      if (c.companionConnected) ...[
        _StatusRow('Registration', '${s['registration'] ?? '–'}', s['registration'] == 'registered' ? _Level.ok : _Level.pending),
        _StatusRow('Glasses', '${s['device'] ?? '–'}${s['mock'] == true ? ' (MOCK)' : ''}', s['device'] != null && s['device'] != 'none' ? _Level.ok : _Level.pending),
        _StatusRow('Camera permission', '${s['permission'] ?? '–'}', switch (s['permission']) {
          'granted' => _Level.ok,
          'denied' => _Level.error,
          _ => _Level.pending,
        }),
        _StatusRow('Stream', '${s['stream'] ?? '–'}${s['resolution'] != null ? ' · ${s['resolution']}' : ''}', streaming ? _Level.ok : _Level.pending),
      ],
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: c.companionConnected && !streaming ? c.startGlassesStream : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start glasses stream'),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: c.companionConnected ? c.stopGlassesStream : null,
          icon: const Icon(Icons.stop),
          label: const Text('Stop'),
        ),
      ]),
    ]);
  }

  Widget _debugSection(BuildContext context) {
    final c = controller;
    final f = c.frame;
    final mono = Theme.of(context).textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], fontFamily: 'Menlo');
    final lines = <String>[
      if (f != null) 'frame ${f.width}x${f.height}  seq ${f.seq}  src ${f.source}',
      'display ${c.displayFps.toStringAsFixed(1)} fps   detect ${c.detectMs.toStringAsFixed(1)} ms',
      'mac pipeline ${c.pipelineMs.toStringAsFixed(1)} ms   dropped ${c.droppedFrames}',
      if (c.glassesToMacMs != null) 'phone→mac (clock-skew dependent) ${c.glassesToMacMs!.toStringAsFixed(0)} ms',
      if (c.serverInfo != null) 'detector ${c.serverInfo!.detector}',
    ];
    return _Section('Debug', [
      for (final l in lines) Text(l, style: mono),
      const SizedBox(height: 8),
      if (c.hands.isEmpty) Text('No hands detected', style: mono),
      for (final h in c.hands) _HandReadout(hand: h, controller: c, style: mono),
    ]);
  }
}

class _HandReadout extends StatelessWidget {
  const _HandReadout({required this.hand, required this.controller, this.style});
  final TrackedHand hand;
  final TrackingController controller;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final pos = controller.positionOf(hand);
    String f(double v, [int d = 3]) => (v >= 0 ? '+' : '') + v.toStringAsFixed(d);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 3, right: 8),
          child: CircleAvatar(radius: 6, backgroundColor: colorForHand(hand.id)),
        ),
        Expanded(
          child: Text(
            '#${hand.id}${hand.identityUncertain ? ' (identity uncertain)' : ''}  ${hand.status.name}  '
            'conf ${hand.confidence.toStringAsFixed(2)}  ${hand.chirality}\n'
            'norm   x ${pos.xn.toStringAsFixed(3)}  y ${pos.yn.toStringAsFixed(3)}\n'
            'rel    x ${f(pos.xr)}  y ${f(pos.yr)}\n'
            'offset x ${f(pos.offsetX, 0)}px  y ${f(pos.offsetY, 0)}px',
            style: style,
          ),
        ),
      ]),
    );
  }
}

enum _Level { ok, pending, error }

class _StatusRow extends StatelessWidget {
  const _StatusRow(this.label, this.value, this.level);
  final String label;
  final String value;
  final _Level level;

  @override
  Widget build(BuildContext context) {
    final color = switch (level) {
      _Level.ok => Colors.greenAccent,
      _Level.pending => Colors.amber,
      _Level.error => Colors.redAccent,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 5, right: 8), child: Icon(Icons.circle, size: 8, color: color)),
        SizedBox(width: 130, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
      ]),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle(this.label, this.value, this.onChanged);
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: onChanged,
      );
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title.toUpperCase(), style: Theme.of(context).textTheme.labelMedium?.copyWith(letterSpacing: 1.2, color: Theme.of(context).colorScheme.primary)),
          const SizedBox(height: 8),
          ...children,
        ]),
      );
}
