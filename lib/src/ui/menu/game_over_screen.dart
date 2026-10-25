import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../platform/app_navigator.dart';
import 'fantasy_theme.dart';

class GameOverScreen extends StatelessWidget {
  const GameOverScreen({super.key, required this.route});
  final GameOverRoute route;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final board = s.leaderboards[route.game.id]!;
    final result = route.result;
    final newBest = route.rank == 1;
    return FantasyBackground(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: FantasyPanel(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('YOU HAVE FALLEN', textAlign: TextAlign.center, style: Fantasy.title(40)),
                const SizedBox(height: 8),
                Text(route.game.title, textAlign: TextAlign.center, style: Fantasy.label),
                const SizedBox(height: 24),
                Text('FINAL SCORE', textAlign: TextAlign.center, style: Fantasy.label),
                Text('${result.score}', textAlign: TextAlign.center, style: Fantasy.title(64).copyWith(color: Fantasy.parchment)),
                if (newBest) Text('A new high score!', textAlign: TextAlign.center, style: Fantasy.body.copyWith(color: Fantasy.gold, fontSize: 18)),
                const SizedBox(height: 12),
                Wrap(alignment: WrapAlignment.center, spacing: 18, children: [
                  for (final MapEntry(:key, :value) in result.stats.entries)
                    Text('$key: $value', style: Fantasy.body.copyWith(color: Fantasy.mist)),
                  Text('Survived: ${(result.duration.inMilliseconds / 1000).toStringAsFixed(0)} s', style: Fantasy.body.copyWith(color: Fantasy.mist)),
                ]),
                const SizedBox(height: 24),
                Text('HALL OF FLAME · TOP 3', style: Fantasy.label),
                const SizedBox(height: 10),
                ListenableBuilder(
                  listenable: board,
                  builder: (_, _) => LeaderboardList(scores: board.top.map((e) => e.score).toList(), highlightRank: route.rank),
                ),
                const SizedBox(height: 28),
                Wrap(alignment: WrapAlignment.center, spacing: 16, runSpacing: 12, children: [
                  FantasyButton(label: 'PLAY AGAIN', icon: Icons.local_fire_department, primary: true, onPressed: s.navigator.playAgain),
                  FantasyButton(label: 'START MENU', icon: Icons.home_outlined, onPressed: s.navigator.openStartMenu),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
