import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metarayzer/src/app/app_settings.dart';
import 'package:metarayzer/src/app/key_value_store.dart';
import 'package:metarayzer/src/app/progression.dart';
import 'package:metarayzer/src/leaderboard/leaderboard.dart';
import 'package:metarayzer/src/platform/app_navigator.dart';
import 'package:metarayzer/src/platform/minigame.dart';

final _game = MinigameDefinition(id: 'g', title: 'G', tagline: '', builder: (_, _) => const SizedBox());

void main() {
  group('Leaderboard', () {
    test('empty board loads gracefully', () async {
      final b = Leaderboard(gameId: 'g', store: MemoryStore());
      await b.load();
      expect(b.top, isEmpty);
    });

    test('keeps the three highest runs, highest first, and reports rank', () async {
      final b = Leaderboard(gameId: 'g', store: MemoryStore());
      await b.load();
      expect(await b.record(50, runId: 'a'), 1);
      expect(await b.record(10, runId: 'b'), 2);
      expect(await b.record(30, runId: 'c'), 2);
      expect(await b.record(5, runId: 'd'), isNull);
      expect(await b.record(70, runId: 'e'), 1);
      expect(b.top.map((e) => e.score), [70, 50, 30]);
    });

    test('equal scores from separate runs are both kept; the newer one must beat, not tie', () async {
      final b = Leaderboard(gameId: 'g', store: MemoryStore());
      final t0 = DateTime(2026);
      await b.record(40, runId: 'a', at: t0);
      await b.record(40, runId: 'b', at: t0.add(const Duration(minutes: 1)));
      await b.record(40, runId: 'c', at: t0.add(const Duration(minutes: 2)));
      expect(b.top.map((e) => e.runId), ['a', 'b', 'c']);
      expect(await b.record(40, runId: 'd', at: t0.add(const Duration(minutes: 3))), isNull);
    });

    test('persists across restarts (new instance, same store)', () async {
      final store = MemoryStore();
      final first = Leaderboard(gameId: 'g', store: store);
      await first.record(123, runId: 'x');
      await first.record(45, runId: 'y');
      final second = Leaderboard(gameId: 'g', store: store);
      await second.load();
      expect(second.top.map((e) => e.score), [123, 45]);
    });

    test('a corrupt stored value does not crash; board starts empty', () async {
      final store = MemoryStore()..values['leaderboard.g'] = '{not json';
      final b = Leaderboard(gameId: 'g', store: store);
      await b.load();
      expect(b.top, isEmpty);
      expect(b.isLoaded, isTrue);
    });
  });

  group('AppSettings', () {
    test('persists preferences (incl. head sensitivity and volumes) but never the simulated input', () async {
      final store = MemoryStore();
      final a = AppSettings(store: store)
        ..dwellSeconds = 1.6
        ..headSensitivity = 1.4
        ..invertHeadYaw = true
        ..sfxVolume = 0.3
        ..ambientVolume = 0.1
        ..spatialMode = SpatialMode.binaural
        ..audioOutput = AudioOutputChoice.companion
        ..simulatedInput = true;
      expect(a.simulatedInput, isTrue);
      await Future<void>.delayed(Duration.zero);
      final b = AppSettings(store: store);
      await b.load();
      expect(b.dwellSeconds, closeTo(1.6, 1e-9));
      expect(b.headSensitivity, closeTo(1.4, 1e-9));
      expect(b.invertHeadYaw, isTrue);
      expect((b.sfxVolume, b.ambientVolume), (0.3, 0.1));
      expect(b.spatialMode, SpatialMode.binaural);
      expect(b.audioOutput, AudioOutputChoice.companion);
      expect(b.simulatedInput, isFalse, reason: 'normal launches always use the real camera');
    });

    test('v2 settings load without errors; removed options are ignored', () async {
      final store = MemoryStore()..values['settings.v1'] = '{"uiControlMode":"hand","dwellSeconds":1.4,"handPreference":"right","showCameraInset":false}';
      final s = AppSettings(store: store);
      await s.load();
      expect(s.dwellSeconds, closeTo(1.4, 1e-9));
      expect(s.showCameraInset, isFalse);
      expect(s.headSensitivity, AppSettings.defaultHeadSensitivity);
    });

    test('sensitivity and volumes are clamped', () {
      final s = AppSettings(store: MemoryStore())
        ..headSensitivity = 5
        ..sfxVolume = -1;
      expect(s.headSensitivity, AppSettings.maxHeadSensitivity);
      expect(s.sfxVolume, 0);
    });

    test('resetting settings keeps permanent progression', () async {
      final store = MemoryStore();
      final settings = AppSettings(store: store)..headSensitivity = 0.4;
      final progression = Progression(store: store);
      await progression.unlock('chain_lightning');
      settings.resetToDefaults();
      final reloaded = Progression(store: store);
      await reloaded.load();
      expect(settings.headSensitivity, AppSettings.defaultHeadSensitivity);
      expect(reloaded.isUnlocked('chain_lightning'), isTrue);
    });

    test('dwell time is clamped to a sane range', () {
      final s = AppSettings(store: MemoryStore())..dwellSeconds = 0.01;
      expect(s.dwellSeconds, AppSettings.minDwellSeconds);
      s.dwellSeconds = 99;
      expect(s.dwellSeconds, AppSettings.maxDwellSeconds);
    });
  });

  group('Progression', () {
    test('unlock persists across restarts and fires only once', () async {
      final store = MemoryStore();
      final p = Progression(store: store);
      await p.load();
      expect(p.isUnlocked('chain_lightning'), isFalse);
      expect(await p.unlock('chain_lightning'), isTrue);
      expect(await p.unlock('chain_lightning'), isFalse);
      final again = Progression(store: store);
      await again.load();
      expect(again.isUnlocked('chain_lightning'), isTrue);
    });
  });

  group('AppNavigator', () {
    test('Start Menu -> Play -> Game Over -> Play Again / Start Menu', () async {
      final recorded = <int>[];
      final nav = AppNavigator(games: [_game], recordResult: (r) async {
        recorded.add(r.score);
        return 1;
      });
      expect(nav.route, isA<StartMenuRoute>());
      nav.playDefault();
      final playing = nav.route as PlayingRoute;
      await nav.finishRun(RunResult(gameId: 'g', runId: playing.runId, score: 42, duration: Duration.zero));
      final over = nav.route as GameOverRoute;
      expect((over.result.score, over.rank), (42, 1));
      expect(recorded, [42]);

      nav.playAgain();
      final second = nav.route as PlayingRoute;
      expect(second.runId, isNot(playing.runId), reason: 'each run gets a fresh id');
      nav.quitRun();
      expect(nav.route, isA<StartMenuRoute>());
      expect(recorded, [42], reason: 'quitting records nothing');
    });

    test('a stale or duplicate finish report is ignored', () async {
      var records = 0;
      final nav = AppNavigator(games: [_game], recordResult: (_) async {
        records++;
        return null;
      });
      nav.playDefault();
      final run = (nav.route as PlayingRoute).runId;
      final result = RunResult(gameId: 'g', runId: run, score: 1, duration: Duration.zero);
      await nav.finishRun(result);
      await nav.finishRun(result);
      expect(records, 1);
      nav.openStartMenu();
      await nav.finishRun(result);
      expect(nav.route, isA<StartMenuRoute>());
    });
  });
}
