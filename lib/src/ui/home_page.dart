import 'package:flutter/material.dart';

import '../app/tracking_controller.dart';
import 'camera_preview.dart';
import 'side_panel.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.controller});
  final TrackingController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final error = controller.lastError;
        return Scaffold(
          body: Column(children: [
            if (error != null)
              MaterialBanner(
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                content: Text(error),
                leading: const Icon(Icons.error_outline),
                actions: [TextButton(onPressed: controller.clearError, child: const Text('Dismiss'))],
              ),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: CameraPreview(controller: controller)),
                const VerticalDivider(width: 1),
                SizedBox(width: 380, child: SidePanel(controller: controller)),
              ]),
            ),
          ]),
        );
      },
    );
  }
}
