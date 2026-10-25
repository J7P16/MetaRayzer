import 'package:flutter/widgets.dart';

import '../audio/audio_service.dart';
import '../input/camera_hand_input.dart';
import '../input/hand_input.dart';
import '../input/hand_input_hub.dart';
import '../input/head_input.dart';
import '../input/simulated_hand_input.dart';
import '../leaderboard/leaderboard.dart';
import '../platform/app_navigator.dart';
import '../platform/minigame.dart';
import 'app_settings.dart';
import 'key_value_store.dart';
import 'progression.dart';
import 'tracking_controller.dart';

/// Long-lived app objects, created once in `main` and shared through [AppScope].
class AppServices {
  AppServices({
    required this.tracking,
    required this.settings,
    required List<MinigameDefinition> games,
    required KeyValueStore store,
  })  : simulated = SimulatedHandInput(),
        progression = Progression(store: store) {
    // The left hand is the only casting hand in this version.
    camera = CameraHandInput(tracking, preference: () => HandPreference.left);
    handInput = HandInputHub(camera: camera, simulated: simulated);
    headInput = HeadInput(tracking.headMotion);
    audio = AudioService(native: tracking.native, settings: settings);
    for (final g in games) {
      leaderboards[g.id] = Leaderboard(gameId: g.id, store: store);
    }
    navigator = AppNavigator(
      games: games,
      recordResult: (result) => leaderboards[result.gameId]!.record(result.score, runId: result.runId),
    );
    settings.addListener(_applySettings);
    _applySettings();
    navigator.addListener(_syncMusic);
    _syncMusic();
  }

  /// Menu music on every non-game screen (the tutorial included); a running game picks its own
  /// day/night track. Same-track requests are ignored, so navigating between menus never
  /// restarts the music.
  void _syncMusic() {
    if (navigator.route is! PlayingRoute) audio.setMusic(MusicTracks.menu);
  }

  final TrackingController tracking;
  final AppSettings settings;
  final SimulatedHandInput simulated;
  final Progression progression;
  late final CameraHandInput camera;
  late final HandInputHub handInput;
  late final HeadInput headInput;
  late final AudioService audio;
  late final AppNavigator navigator;
  final Map<String, Leaderboard> leaderboards = {};

  Future<void> load() async {
    await settings.load();
    await progression.load();
    await Future.wait(leaderboards.values.map((l) => l.load()));
  }

  void _applySettings() {
    handInput.useSimulated = settings.simulatedInput;
    headInput.simulated = settings.simulatedInput;
  }
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});
  final AppServices services;

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope old) => old.services != services;
}
