import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/app_navigator.dart';
import '../platform/minigame.dart';
import '../ui/dwell/dwell_scope.dart';
import '../ui/camera_stream_indicator.dart';
import '../ui/home_page.dart';
import '../ui/menu/fantasy_theme.dart';
import '../ui/menu/game_over_screen.dart';
import '../ui/menu/settings_screen.dart';
import '../ui/menu/start_menu.dart';
import 'app_services.dart';

/// Root of the game platform: routes between screens, hosts the hand-dwell UI layer, feeds the
/// development simulated hand from the mouse/keyboard, and handles global keys (Esc).
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.services});
  final AppServices services;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppServices get s => widget.services;
  final GlobalKey _areaKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      final route = s.navigator.route;
      if (route is PlayingRoute) {
        s.navigator.quitRun();
        return true;
      }
      if (route is SetupRoute || route is SettingsRoute) {
        s.navigator.openStartMenu();
        return true;
      }
    }
    // Simulated hand (dev): Space or F held = fist.
    if (s.settings.simulatedInput && (key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.keyF)) {
      if (event is KeyDownEvent) s.simulated.setFist(true);
      if (event is KeyUpEvent) s.simulated.setFist(false);
      return s.navigator.route is PlayingRoute; // don't steal Space from focused menu buttons
    }
    return false;
  }

  void _pointer(PointerEvent e, {bool? down}) {
    if (!s.settings.simulatedInput) return;
    final box = _areaKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(e.position);
    s.simulated.move(Offset(local.dx / box.size.width, local.dy / box.size.height));
    if (down != null) s.simulated.setFist(down);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: s,
      child: ListenableBuilder(
        listenable: Listenable.merge([s.navigator, s.settings]),
        builder: (context, _) {
          final route = s.navigator.route;
          // Mouse and hand navigation are both always on; hand dwell pauses during gameplay,
          // where the hand casts spells instead.
          final handUi = route is! PlayingRoute;
          return Listener(
            key: _areaKey,
            behavior: HitTestBehavior.translucent,
            onPointerHover: _pointer,
            onPointerMove: _pointer,
            onPointerDown: (e) => _pointer(e, down: true),
            onPointerUp: (e) => _pointer(e, down: false),
            child: MouseRegion(
              onExit: (_) => s.simulated.move(null),
              child: DwellScope(
                enabled: handUi,
                input: s.handInput,
                dwellSeconds: s.settings.dwellSeconds,
                onHoverStart: s.audio.uiHover,
                onActivated: s.audio.uiSelect,
                child: Stack(fit: StackFit.expand, children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    child: KeyedSubtree(key: ValueKey(_routeKey(route)), child: _screenFor(route)),
                  ),
                  if (route is! PlayingRoute) Positioned(top: 10, right: 16, child: CameraStreamIndicator(tracking: s.tracking)),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Object _routeKey(AppRoute route) => switch (route) {
        PlayingRoute(:final runId) => 'play-$runId',
        GameOverRoute(:final result) => 'over-${result.runId}',
        _ => route.runtimeType,
      };

  Widget _screenFor(AppRoute route) => switch (route) {
        StartMenuRoute() => const StartMenu(),
        PlayingRoute(:final game, :final runId) => game.builder(
            context,
            MinigameHost(
              handInput: s.handInput,
              headInput: s.headInput,
              audio: s.audio,
              progression: s.progression,
              settings: s.settings,
              tracking: s.tracking,
              runId: runId,
              onFinished: s.navigator.finishRun,
              onQuit: s.navigator.quitRun,
            ),
          ),
        GameOverRoute() => GameOverScreen(route: route),
        SetupRoute() => _SetupScreen(services: s),
        SettingsRoute() => const SettingsScreen(),
      };
}

/// The original glasses/tracking debug view, reachable from the Start Menu.
class _SetupScreen extends StatelessWidget {
  const _SetupScreen({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Fantasy.night,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              FantasyButton(label: 'Back to menu', icon: Icons.arrow_back, compact: true, onPressed: services.navigator.openStartMenu),
              const SizedBox(width: 16),
              Text('GLASSES & TRACKING SETUP', style: Fantasy.label),
            ]),
          ),
          Expanded(child: HomePage(controller: services.tracking)),
        ]),
      );
}
