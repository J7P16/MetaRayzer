import 'package:shared_preferences/shared_preferences.dart';

/// Minimal persistence interface so settings and leaderboards can be tested without a platform.
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

/// Local persistence via `shared_preferences` (NSUserDefaults on macOS; survives restarts).
class SharedPrefsStore implements KeyValueStore {
  Future<SharedPreferences>? _prefs;
  Future<SharedPreferences> get _instance => _prefs ??= SharedPreferences.getInstance();

  @override
  Future<String?> getString(String key) async => (await _instance).getString(key);

  @override
  Future<void> setString(String key, String value) async => (await _instance).setString(key, value);
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}
