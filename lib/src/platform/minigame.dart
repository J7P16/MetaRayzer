import 'package:flutter/widgets.dart';

import '../app/app_settings.dart';
import '../app/progression.dart';
import '../app/tracking_controller.dart';
import '../audio/audio_service.dart';
import '../input/hand_input_hub.dart';
import '../input/head_input.dart';

/// Result of one finished run of a minigame.
@immutable
class RunResult {
  const RunResult({required this.gameId, required this.runId, required this.score, required this.duration, this.stats = const {}});

  final String gameId;
  final String runId;
  final int score;
  final Duration duration;

  /// Game-specific extras for the results screen (e.g. "Enemies defeated": 12).
  final Map<String, Object> stats;
}

/// What the platform gives a running minigame. Minigames never talk to the camera pipeline or
/// the navigator directly.
class MinigameHost {
  const MinigameHost({
    required this.handInput,
    required this.headInput,
    required this.audio,
    required this.progression,
    required this.settings,
    required this.tracking,
    required this.runId,
    required this.onFinished,
    required this.onQuit,
  });

  /// Hand status, position and pose. The only input a game should need.
  final HandInputHub handInput;

  /// Head orientation (glasses Motion, when available) for view/aim.
  final HeadInput headInput;
  final AudioService audio;

  /// Permanent unlocks (separate from settings).
  final Progression progression;
  final AppSettings settings;

  /// Exposed only for optional camera-preview insets; games must not read frames from it.
  final TrackingController tracking;
  final String runId;

  /// The run ended normally (e.g. out of lives): show results.
  final void Function(RunResult result) onFinished;

  /// The player aborted the run: back to the menu, nothing recorded.
  final VoidCallback onQuit;
}

/// A playable minigame. Register new games in [kMinigames]; a future Game Select screen lists
/// this registry, and navigation/results/leaderboards work for any entry.
@immutable
class MinigameDefinition {
  const MinigameDefinition({required this.id, required this.title, required this.tagline, required this.builder});

  /// Stable id, also used as the leaderboard key.
  final String id;
  final String title;
  final String tagline;
  final Widget Function(BuildContext context, MinigameHost host) builder;
}
