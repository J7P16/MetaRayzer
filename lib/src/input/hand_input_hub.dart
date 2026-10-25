import 'package:flutter/foundation.dart';

import 'hand_input.dart';
import 'simulated_hand_input.dart';

/// The single hand-input feed the app consumes. Switches between the camera source and the
/// development [SimulatedHandInput] without consumers having to re-subscribe; only the active
/// source's updates are forwarded.
class HandInputHub extends ChangeNotifier implements ValueListenable<HandInputFrame> {
  HandInputHub({required this.camera, required this.simulated}) {
    camera.addListener(_onCamera);
    simulated.addListener(_onSimulated);
  }

  final HandInputSource camera;
  final SimulatedHandInput simulated;
  bool _useSimulated = false;

  bool get useSimulated => _useSimulated;
  HandInputSource get active => _useSimulated ? simulated : camera;

  set useSimulated(bool value) {
    if (value == _useSimulated) return;
    _useSimulated = value;
    simulated.active = value;
    notifyListeners();
  }

  @override
  HandInputFrame get value => active.value;

  void _onCamera() {
    if (!_useSimulated) notifyListeners();
  }

  void _onSimulated() {
    if (_useSimulated) notifyListeners();
  }

  @override
  void dispose() {
    camera.removeListener(_onCamera);
    simulated.removeListener(_onSimulated);
    simulated.active = false;
    super.dispose();
  }
}
