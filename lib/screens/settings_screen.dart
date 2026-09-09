import 'package:flutter/material.dart';

import '../services/tag_db.dart';

/// Settings screen: stores the TheGamesDB API key (used for metadata + covers).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TagDb _db = TagDb();
  final _keyController = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final key = await _db.getSetting('thegamesdb_api_key');
    if (!mounted) return;
    setState(() {
      _keyController.text = key ?? '';
      _loaded = true;
    });
  }

  Future<void> _save() async {
    await _db.saveSetting('thegamesdb_api_key', _keyController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('API key saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loaded
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'TheGamesDB API key',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Used to look up real game titles and cover art. Get a free '
                  'key at thegamesdb.net (create an account, then visit '
                  'api.thegamesdb.net/key.php). Stored only on this device.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keyController,
                  decoration: const InputDecoration(
                    labelText: 'API key',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save key'),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
