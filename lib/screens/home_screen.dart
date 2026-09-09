import 'package:flutter/material.dart';

import 'import_screen.dart';
import 'library_screen.dart';
import 'settings_screen.dart';

/// Home shell: Library and Import tabs, plus a settings entry point.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ROM Organizer'),
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Library'),
              Tab(text: 'Import'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            LibraryScreen(),
            ImportScreen(),
          ],
        ),
      ),
    );
  }
}
