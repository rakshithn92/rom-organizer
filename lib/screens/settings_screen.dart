import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool _obscureKey = true;

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
                  'key from TheGamesDB, then paste it below. Stored only on '
                  'this device.',
                ),
                const SizedBox(height: 8),
                // Clickable links to the site + key page.
                LinkButton(
                  icon: Icons.language,
                  label: 'Open thegamesdb.net',
                  url: 'https://thegamesdb.net',
                ),
                LinkButton(
                  icon: Icons.key,
                  label: 'Get your API key',
                  url: 'https://api.thegamesdb.net/key.php',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _keyController,
                  obscureText: _obscureKey,
                  decoration: InputDecoration(
                    labelText: 'API key',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscureKey ? Icons.visibility : Icons.visibility_off),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
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

/// A tappable row that opens [url] in the browser.
class LinkButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;
  const LinkButton({
    super.key,
    required this.icon,
    required this.label,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label, style: const TextStyle(color: Colors.blue)),
      trailing: const Icon(Icons.open_in_new, size: 18),
      onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    );
  }
}
