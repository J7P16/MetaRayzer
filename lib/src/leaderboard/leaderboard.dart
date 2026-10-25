import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../app/key_value_store.dart';

@immutable
class ScoreEntry {
  const ScoreEntry({required this.score, required this.achievedAt, required this.runId});

  final int score;
  final DateTime achievedAt;

  /// Unique per run, so two runs with equal scores are both kept and the current run can be
  /// highlighted on the results screen.
  final String runId;

  Map<String, Object> toJson() => {'score': score, 'at': achievedAt.toIso8601String(), 'run': runId};

  static ScoreEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final score = json['score'], at = json['at'], run = json['run'];
    if (score is! int || at is! String || run is! String) return null;
    final time = DateTime.tryParse(at);
    return time == null ? null : ScoreEntry(score: score, achievedAt: time, runId: run);
  }
}

/// Local top-N leaderboard for one minigame, persisted across restarts.
///
/// Ordering: higher score first; equal scores keep the earlier run first (the newer run must
/// beat, not tie, an existing entry to push it out).
class Leaderboard extends ChangeNotifier {
  Leaderboard({required this.gameId, required this._store, this.size = 3});

  final String gameId;
  final int size;
  final KeyValueStore _store;
  List<ScoreEntry> _entries = const [];
  bool _loaded = false;

  String get _key => 'leaderboard.$gameId';
  List<ScoreEntry> get top => _entries;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final raw = await _store.getString(_key);
      if (raw != null) {
        final list = (jsonDecode(raw) as List).map(ScoreEntry.fromJson).whereType<ScoreEntry>().toList();
        _entries = _sorted(list).take(size).toList(growable: false);
      }
    } catch (e) {
      // A corrupt store must never block the game; start empty.
      developer.log('leaderboard load failed: $e', name: 'metarayzer');
    }
    _loaded = true;
    debugPrint('[metarayzer] leaderboard $gameId: ${_entries.map((e) => e.score).toList()}');
    notifyListeners();
  }

  /// Records a finished run. Returns its 1-based rank if it made the top [size], else null.
  Future<int?> record(int score, {required String runId, DateTime? at}) async {
    final entry = ScoreEntry(score: score, achievedAt: at ?? DateTime.now(), runId: runId);
    final all = _sorted([..._entries, entry]);
    _entries = all.take(size).toList(growable: false);
    notifyListeners();
    try {
      await _store.setString(_key, jsonEncode(_entries.map((e) => e.toJson()).toList()));
    } catch (e) {
      developer.log('leaderboard save failed: $e', name: 'metarayzer');
    }
    final index = _entries.indexWhere((e) => e.runId == runId);
    return index < 0 ? null : index + 1;
  }

  static List<ScoreEntry> _sorted(List<ScoreEntry> list) => list
    ..sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.achievedAt.compareTo(b.achievedAt);
    });
}
