import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../input/hand_input.dart';
import 'key_value_store.dart';

/// How menus and buttons are operated.
enum UiControlMode {
  /// Mouse clicks (and keyboard). Always works, even without glasses.
  mouse,

  /// Hand cursor + dwell-to-select. Mouse clicks keep working as well.
  hand,
}

/// User preferences, persisted locally.
class AppSettings extends ChangeNotifier {
  AppSettings({required this._store});

  final KeyValueStore _store;
  static const _key = 'settings.v1';

  static const double minDwellSeconds = 0.4;
  static const double maxDwellSeconds = 3.0;

  UiControlMode _uiControlMode = UiControlMode.mouse;
  double _dwellSeconds = 1.0;
  HandPreference _handPreference = HandPreference.left;
  bool _simulatedHand = false;
  bool _showCameraInset = true;

  UiControlMode get uiControlMode => _uiControlMode;
  double get dwellSeconds => _dwellSeconds;
  HandPreference get handPreference => _handPreference;

  /// Development only: drive hand input with the mouse/keyboard instead of the camera.
  bool get simulatedHand => _simulatedHand;
  bool get showCameraInset => _showCameraInset;

  set uiControlMode(UiControlMode v) => _set(() => _uiControlMode = v);
  set dwellSeconds(double v) => _set(() => _dwellSeconds = v.clamp(minDwellSeconds, maxDwellSeconds));
  set handPreference(HandPreference v) => _set(() => _handPreference = v);
  set simulatedHand(bool v) => _set(() => _simulatedHand = v);
  set showCameraInset(bool v) => _set(() => _showCameraInset = v);

  void _set(VoidCallback change) {
    change();
    notifyListeners();
    _save();
  }

  Future<void> load() async {
    try {
      final raw = await _store.getString(_key);
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      _uiControlMode = UiControlMode.values.asNameMap()[m['uiControlMode']] ?? _uiControlMode;
      _dwellSeconds = ((m['dwellSeconds'] as num?)?.toDouble() ?? _dwellSeconds).clamp(minDwellSeconds, maxDwellSeconds);
      _handPreference = HandPreference.values.asNameMap()[m['handPreference']] ?? _handPreference;
      // Simulated input is never restored: a normal launch always uses the real camera.
      _showCameraInset = m['showCameraInset'] as bool? ?? _showCameraInset;
      notifyListeners();
    } catch (_) {
      // Ignore corrupt settings; defaults apply.
    }
  }

  Future<void> _save() => _store.setString(
        _key,
        jsonEncode({
          'uiControlMode': _uiControlMode.name,
          'dwellSeconds': _dwellSeconds,
          'handPreference': _handPreference.name,
          'showCameraInset': _showCameraInset,
        }),
      );
}
