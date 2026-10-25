import 'dart:typed_data';

import '../geometry/hand_geometry.dart';
import 'one_euro_filter.dart';

/// One hand detection in one frame, already reduced to a center point.
class HandObservation {
  const HandObservation({required this.center, this.box, required this.confidence, this.chirality = 'unknown', this.landmarks});
  final NormPoint center;
  final NormRect? box;
  final double confidence;
  final String chirality;
  final Float64List? landmarks;
}

enum TrackStatus {
  /// Seen, but not yet for enough consecutive frames to be shown.
  tentative,

  /// Matched in the latest processed frame.
  active,

  /// Not matched in the latest frame; holding the last position until [HandTrackerConfig.holdMs].
  coasting,
}

class TrackedHand {
  TrackedHand._(this.id, HandObservation obs, double tMs, HandTrackerConfig config)
      : _fx = config.newFilter(),
        _fy = config.newFilter(),
        raw = obs.center,
        smoothed = obs.center,
        box = obs.box,
        confidence = obs.confidence,
        chirality = obs.chirality,
        landmarks = obs.landmarks,
        lastSeenMs = tMs,
        firstSeenMs = tMs {
    _fx.filter(obs.center.x, tMs / 1000);
    _fy.filter(obs.center.y, tMs / 1000);
  }

  /// Temporary tracking id, unique for this tracker's lifetime. Not a claim about *which*
  /// physical hand this is beyond "probably the same one as in the previous frames".
  final int id;
  NormPoint raw;
  NormPoint smoothed;
  NormRect? box;
  double confidence;
  String chirality;
  Float64List? landmarks;
  double lastSeenMs;
  final double firstSeenMs;
  int hits = 1;
  int misses = 0;
  TrackStatus status = TrackStatus.tentative;

  /// True while the tracker could not reliably tell this hand apart from another one (hands
  /// crossing or overlapping). The id is kept but should not be trusted.
  bool identityUncertain = false;
  int _uncertainFramesLeft = 0;

  final OneEuroFilter _fx;
  final OneEuroFilter _fy;

  bool get isVisible => status != TrackStatus.tentative;

  void _update(HandObservation obs, double tMs) {
    raw = obs.center;
    smoothed = NormPoint(_fx.filter(obs.center.x, tMs / 1000), _fy.filter(obs.center.y, tMs / 1000));
    box = obs.box;
    confidence = obs.confidence;
    if (obs.chirality != 'unknown') chirality = obs.chirality;
    landmarks = obs.landmarks;
    lastSeenMs = tMs;
    hits++;
    misses = 0;
  }

  @override
  String toString() => 'TrackedHand(#$id ${status.name} $smoothed conf=${confidence.toStringAsFixed(2)}${identityUncertain ? ' ?' : ''})';
}

class HandTrackerConfig {
  const HandTrackerConfig({
    this.maxHands = 2,
    this.minConfidence = 0.5,
    this.matchDistance = 0.2,
    this.minHitsToConfirm = 2,
    this.holdMs = 300,
    this.staleMs = 1000,
    this.duplicateIou = 0.6,
    this.ambiguityMargin = 0.04,
    this.overlapDistance = 0.06,
    this.uncertainHoldFrames = 6,
    this.chiralityPenalty = 0.03,
    this.filterMinCutoff = 1.2,
    this.filterBeta = 2.0,
  });

  final int maxHands;

  /// Detections below this confidence are ignored.
  final double minConfidence;

  /// Max center movement between frames (fraction of the frame diagonal) to count as the same hand.
  final double matchDistance;

  /// Consecutive detections required before a new hand is shown (suppresses one-frame false positives).
  final int minHitsToConfirm;

  /// How long a lost hand keeps its indicator before it is removed.
  final double holdMs;

  /// Any track (even an "active" one) not seen for this long is removed. This covers the case
  /// where frames stop arriving entirely, so no update ever demotes the track to coasting.
  final double staleMs;

  /// Two detections whose boxes overlap more than this are treated as one hand (keep the more confident).
  final double duplicateIou;

  /// If swapping the two identities costs less than this extra distance, identity is ambiguous.
  final double ambiguityMargin;

  /// Hand centers closer than this (fraction of diagonal) are treated as overlapping.
  final double overlapDistance;

  /// Frames an identity stays flagged uncertain after the ambiguity clears.
  final int uncertainHoldFrames;

  /// Extra matching cost when the detector's left/right label disagrees with the track's.
  final double chiralityPenalty;

  final double filterMinCutoff;
  final double filterBeta;

  OneEuroFilter newFilter() => OneEuroFilter(minCutoff: filterMinCutoff, beta: filterBeta);
}

/// Multi-hand tracker: frame-to-frame association with gating, temporary ids, One Euro
/// smoothing, short hold-then-expire for lost hands, and explicit "identity uncertain" when
/// hands cross or overlap. Pure Dart, no Flutter dependency, so it is unit-testable.
class HandTracker {
  HandTracker({this.config = const HandTrackerConfig()});

  final HandTrackerConfig config;
  final List<TrackedHand> _tracks = [];
  int _nextId = 1;

  /// All tracks, including tentative ones.
  List<TrackedHand> get tracks => List.unmodifiable(_tracks);

  /// Tracks that should be drawn.
  List<TrackedHand> get visibleTracks => _tracks.where((t) => t.isVisible).toList(growable: false);

  void reset() {
    _tracks.clear();
  }

  /// Feeds the detections for one processed frame taken at [tMs] (milliseconds, monotonic).
  /// [aspect] is frame width / height, used for distance so portrait frames behave correctly.
  List<TrackedHand> update(List<HandObservation> detections, double tMs, {double aspect = 1}) {
    final candidates = _filterDetections(detections);
    final assignment = _associate(candidates, aspect);

    final matchedTracks = <TrackedHand>{};
    final matchedDetections = <int>{};
    assignment.pairs.forEach((trackIndex, detIndex) {
      final track = _tracks[trackIndex];
      track._update(candidates[detIndex], tMs);
      matchedTracks.add(track);
      matchedDetections.add(detIndex);
    });

    // Unmatched tracks: tentative ones vanish immediately, confirmed ones coast then expire.
    for (final track in List.of(_tracks)) {
      if (matchedTracks.contains(track)) continue;
      track.misses++;
      if (track.status == TrackStatus.tentative) {
        _tracks.remove(track);
      } else {
        track.status = TrackStatus.coasting;
      }
    }

    // New tracks for unmatched detections, evicting the stalest coasting track if we're full.
    for (var i = 0; i < candidates.length; i++) {
      if (matchedDetections.contains(i)) continue;
      if (_tracks.length >= config.maxHands) {
        final coasting = _tracks.where((t) => t.status == TrackStatus.coasting).toList()
          ..sort((a, b) => a.lastSeenMs.compareTo(b.lastSeenMs));
        if (coasting.isEmpty) continue;
        _tracks.remove(coasting.first);
      }
      _tracks.add(TrackedHand._(_nextId++, candidates[i], tMs, config));
    }

    for (final track in _tracks) {
      final seenThisFrame = matchedTracks.contains(track) || track.misses == 0; // matched or just created
      if (seenThisFrame) {
        track.status = track.hits >= config.minHitsToConfirm ? TrackStatus.active : TrackStatus.tentative;
      }
    }

    _updateIdentityConfidence(assignment.ambiguous, aspect);
    expire(tMs);
    return visibleTracks;
  }

  /// Drops coasting tracks older than [HandTrackerConfig.holdMs] and any track older than
  /// [HandTrackerConfig.staleMs]. Call this periodically too, so indicators disappear even when
  /// frames stop arriving altogether.
  List<TrackedHand> expire(double nowMs) {
    _tracks.removeWhere((t) {
      final age = nowMs - t.lastSeenMs;
      return age > config.staleMs || (t.status == TrackStatus.coasting && age > config.holdMs);
    });
    return visibleTracks;
  }

  List<HandObservation> _filterDetections(List<HandObservation> detections) {
    final sorted = detections.where((d) => d.confidence >= config.minConfidence).toList()
      ..sort((a, b) => b.confidence.compareTo(a.confidence));
    // Non-max suppression: the detector occasionally reports the same hand twice.
    final kept = <HandObservation>[];
    for (final d in sorted) {
      final duplicate = kept.any((k) => k.box != null && d.box != null && k.box!.iou(d.box!) > config.duplicateIou);
      if (!duplicate) kept.add(d);
      if (kept.length == config.maxHands) break;
    }
    return kept;
  }

  double _cost(TrackedHand track, HandObservation obs, double aspect) {
    // Compare against the raw (unsmoothed) last position; smoothing lag would bias matching.
    var cost = track.raw.distanceTo(obs.center, aspect: aspect);
    if (track.chirality != 'unknown' && obs.chirality != 'unknown' && track.chirality != obs.chirality) {
      cost += config.chiralityPenalty;
    }
    return cost;
  }

  /// Globally optimal assignment for the tiny problem sizes we have (<= maxHands on each side):
  /// maximize the number of gated matches, then minimize total cost.
  _Assignment _associate(List<HandObservation> detections, double aspect) {
    final n = _tracks.length;
    final m = detections.length;
    if (n == 0 || m == 0) return const _Assignment({}, false);

    final costs = List.generate(n, (i) => List.generate(m, (j) => _cost(_tracks[i], detections[j], aspect)));

    var best = <int, int>{};
    var bestCost = double.infinity;
    final options = <({Map<int, int> pairs, double cost})>[];

    void search(int i, Map<int, int> pairs, Set<int> used, double cost) {
      if (i == n) {
        options.add((pairs: Map.of(pairs), cost: cost));
        if (pairs.length > best.length || (pairs.length == best.length && cost < bestCost)) {
          best = Map.of(pairs);
          bestCost = cost;
        }
        return;
      }
      search(i + 1, pairs, used, cost); // track i unmatched
      for (var j = 0; j < m; j++) {
        if (used.contains(j) || costs[i][j] > config.matchDistance) continue;
        pairs[i] = j;
        used.add(j);
        search(i + 1, pairs, used, cost + costs[i][j]);
        pairs.remove(i);
        used.remove(j);
      }
    }

    search(0, {}, {}, 0);

    // Ambiguous if a different assignment of the same size, involving 2+ visible tracks, is
    // nearly as cheap: e.g. two hands crossing paths.
    var ambiguous = false;
    if (best.length >= 2) {
      for (final o in options) {
        if (o.pairs.length != best.length || _samePairs(o.pairs, best)) continue;
        if (o.cost - bestCost < config.ambiguityMargin) {
          ambiguous = true;
          break;
        }
      }
    }
    return _Assignment(best, ambiguous);
  }

  static bool _samePairs(Map<int, int> a, Map<int, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  void _updateIdentityConfidence(bool assignmentAmbiguous, double aspect) {
    final visible = _tracks.where((t) => t.status == TrackStatus.active).toList();
    var overlapping = false;
    for (var i = 0; i < visible.length; i++) {
      for (var j = i + 1; j < visible.length; j++) {
        if (visible[i].raw.distanceTo(visible[j].raw, aspect: aspect) < config.overlapDistance) overlapping = true;
      }
    }
    final ambiguousNow = assignmentAmbiguous || overlapping;
    for (final t in _tracks) {
      if (ambiguousNow && t.status == TrackStatus.active && visible.length >= 2) {
        t._uncertainFramesLeft = config.uncertainHoldFrames;
      } else if (t._uncertainFramesLeft > 0) {
        t._uncertainFramesLeft--;
      }
      t.identityUncertain = t._uncertainFramesLeft > 0;
    }
  }
}

class _Assignment {
  const _Assignment(this.pairs, this.ambiguous);

  /// track index -> detection index
  final Map<int, int> pairs;
  final bool ambiguous;
}
