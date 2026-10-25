import 'package:flutter/material.dart';

import 'src/app/app_services.dart';
import 'src/app/app_settings.dart';
import 'src/app/app_shell.dart';
import 'src/app/key_value_store.dart';
import 'src/app/tracking_controller.dart';
import 'src/games/wizard/wizard_screen.dart';
import 'src/platform/minigame.dart';

/// All playable minigames. A future Game Select screen lists these.
const List<MinigameDefinition> kMinigames = [wizardShooter];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SharedPrefsStore();
  final services = AppServices(
    tracking: TrackingController()..start(),
    settings: AppSettings(store: store),
    games: kMinigames,
    store: store,
  );
  await services.load();
  runApp(MetaRayzerApp(services: services));
}

class MetaRayzerApp extends StatelessWidget {
  const MetaRayzerApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MetaRayzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF00B8D4), brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(body: AppShell(services: services)),
    );
  }
}
