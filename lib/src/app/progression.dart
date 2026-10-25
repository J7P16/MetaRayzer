import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'key_value_store.dart';

/// Permanent, per-local-player progression (e.g. unlocked spells). Stored under its own key,
/// separate from [AppSettings], so resetting preferences never erases unlocks.
class Progression extends ChangeNotifier {
  Progression({required this._store});

  final KeyValueStore _store;
  static const _key = 'progression.v1';

  final Set<String> _unlocked = {};

  Set<String> get unlocked => Set.unmodifiable(_unlocked);
  bool isUnlocked(String id) => _unlocked.contains(id);

  Future<void> load() async {
    try {
      final raw = await _store.getString(_key);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        _unlocked.addAll((m['unlocked'] as List? ?? const []).whereType<String>());
      }
    } catch (e) {
      developer.log('progression load failed: $e', name: 'metarayzer');
    }
    notifyListeners();
  }

  /// Unlocks [id] permanently. Returns true only the first time (callers show the reward once).
  Future<bool> unlock(String id) async {
    if (!_unlocked.add(id)) return false;
    notifyListeners();
    debugPrint('[metarayzer] unlocked: $id');
    try {
      await _store.setString(_key, jsonEncode({'unlocked': _unlocked.toList()..sort()}));
    } catch (e) {
      developer.log('progression save failed: $e', name: 'metarayzer');
    }
    return true;
  }
}
