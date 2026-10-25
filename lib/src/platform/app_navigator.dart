import 'package:flutter/foundation.dart';

import 'minigame.dart';

/// Screens of the app. Intended long-term flow:
///   StartMenu → GameSelect → Playing → GameOver → GameSelect
/// This version has a single game, so Play goes straight to it; adding a `GameSelectRoute`
/// only needs a new route class, a screen, and changing [AppNavigator.playDefault].
sealed class AppRoute {
  const AppRoute();
}

class StartMenuRoute extends AppRoute {
  const StartMenuRoute();
}

class PlayingRoute extends AppRoute {
  const PlayingRoute(this.game, this.runId);
  final MinigameDefinition game;
  final String runId;
}

class GameOverRoute extends AppRoute {
  const GameOverRoute({required this.game, required this.result, required this.rank});
  final MinigameDefinition game;
  final RunResult result;

  /// 1-based leaderboard position of this run, or null if it didn't place.
  final int? rank;
}

/// The existing glasses/tracking setup and debug view.
class SetupRoute extends AppRoute {
  const SetupRoute();
}

/// Preferences: head sensitivity, audio, menu hover time.
class SettingsRoute extends AppRoute {
  const SettingsRoute();
}

/// App-level navigation state. A single source of truth makes it impossible for a game to keep
/// running behind the results screen: leaving [PlayingRoute] disposes the game widget.
class AppNavigator extends ChangeNotifier {
  AppNavigator({required this.games, this.recordResult}) : assert(games.isNotEmpty);

  final List<MinigameDefinition> games;

  /// Persists a finished run and returns its leaderboard rank.
  final Future<int?> Function(RunResult result)? recordResult;

  AppRoute _route = const StartMenuRoute();
  int _runCounter = 0;

  AppRoute get route => _route;

  void _go(AppRoute route) {
    debugPrint('[metarayzer] screen: ${route.runtimeType}');
    _route = route;
    notifyListeners();
  }

  void openStartMenu() => _go(const StartMenuRoute());
  void openSetup() => _go(const SetupRoute());
  void openSettings() => _go(const SettingsRoute());

  /// Play button. With one game there is no Game Select yet.
  void playDefault() => play(games.first);

  void play(MinigameDefinition game) {
    _runCounter++;
    _go(PlayingRoute(game, '${DateTime.now().microsecondsSinceEpoch}-$_runCounter'));
  }

  /// Called by the running game when the run ends.
  Future<void> finishRun(RunResult result) async {
    final current = _route;
    // Ignore stale/double reports (e.g. a game that already left the screen).
    if (current is! PlayingRoute || current.runId != result.runId) return;
    final rank = await recordResult?.call(result);
    if (_route is PlayingRoute && (_route as PlayingRoute).runId == result.runId) {
      _go(GameOverRoute(game: current.game, result: result, rank: rank));
    }
  }

  /// Quit mid-run (Esc): nothing is recorded.
  void quitRun() {
    if (_route is PlayingRoute) openStartMenu();
  }

  void playAgain() {
    final current = _route;
    play(current is GameOverRoute ? current.game : games.first);
  }
}
