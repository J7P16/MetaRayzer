import 'package:flutter/material.dart';

import 'src/app/tracking_controller.dart';
import 'src/ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = TrackingController()..start();
  runApp(MetaRayzerApp(controller: controller));
}

class MetaRayzerApp extends StatelessWidget {
  const MetaRayzerApp({super.key, required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MetaRayzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF00B8D4), brightness: Brightness.dark, useMaterial3: true),
      home: HomePage(controller: controller),
    );
  }
}
