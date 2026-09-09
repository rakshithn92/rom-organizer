import 'package:flutter/material.dart';

import 'screens/browser_screen.dart';
import 'screens/permission_gate.dart';

void main() {
  runApp(const RomOrganizerApp());
}

class RomOrganizerApp extends StatelessWidget {
  const RomOrganizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ROM Organizer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const PermissionGate(child: BrowserScreen()),
    );
  }
}
