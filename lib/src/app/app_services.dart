import 'package:flutter/widgets.dart';

import '../input/camera_hand_input.dart';
import '../input/hand_input_hub.dart';
import '../input/simulated_hand_input.dart';
import '../leaderboard/leaderboard.dart';
import '../platform/app_navigator.dart';
import '../platform/minigame.dart';
import 'app_settings.dart';
import 'key_value_store.dart';
import 'tracking_controller.dart';

/// Long-lived app objects, created once in `main` and shared through [AppScope].
class AppServices {
  AppServices({
    required this.tracking,
    required this.settings,
    required List<MinigameDefinition> games,
    required KeyValueStore store,
  }) : simulated = SimulatedHandInput() {
    camera = CameraHandInput(tracking, preference: () => settings.handPreference);
    handInput = HandInputHub(camera: camera, simulated: simulated);
    for (final g in games) {
      leaderboards[g.id] = Leaderboard(gameId: g.id, store: store);
    }
    navigator = AppNavigator(
      games: games,
      recordResult: (result) => leaderboards[result.gameId]!.record(result.score, runId: result.runId),
    );
    settings.addListener(_applySettings);
    _applySettings();
  }

  final TrackingController tracking;
  final AppSettings settings;
  final SimulatedHandInput simulated;
  late final CameraHandInput camera;
  late final HandInputHub handInput;
  late final AppNavigator navigator;
  final Map<String, Leaderboard> leaderboards = {};

  Future<void> load() async {
    await settings.load();
    await Future.wait(leaderboards.values.map((l) => l.load()));
  }

  void _applySettings() => handInput.useSimulated = settings.simulatedHand;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});
  final AppServices services;

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope old) => old.services != services;
}
