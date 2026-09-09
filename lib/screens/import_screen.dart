import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/importer.dart';
import '../services/tag_db.dart';
import '../services/thegamesdb_client.dart';
import '../services/title_parser.dart';

/// Import flow: browse to a zip, auto-title it from TheGamesDB, extract into
/// the per-game library layout, then offer to delete the zip once fully
/// extracted (to reclaim space).
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  static const _libraryRoot = '/storage/emulated/0/ROMs/Switch';
  final TagDb _db = TagDb();

  Directory _current = Directory('/storage/emulated/0');
  List<Directory> _subdirs = [];
  List<File> _zips = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dirs = <Directory>[];
    final zips = <File>[];
    try {
      for (final e in _current.listSync(followLinks: false)) {
        if (e is Directory) {
          dirs.add(e);
        } else if (e is File && p.extension(e.path).toLowerCase() == '.zip') {
          zips.add(e);
        }
      }
    } catch (_) {
      // Unreadable dir — show empty.
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));
    zips.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    setState(() {
      _subdirs = dirs;
      _zips = zips;
    });
  }

  void _enter(Directory d) {
    setState(() => _current = d);
    _load();
  }

  void _up() {
    final parent = _current.parent;
    if (parent.path == _current.path) return;
    setState(() => _current = parent);
    _load();
  }

  Future<void> _import(File zip) async {
    setState(() => _busy = true);

    // 1. Candidate title from the filename.
    final candidate = TitleParser.clean(p.basename(zip.path));

    // 2. Look up the real title from TheGamesDB (if a key is set).
    var resolved = candidate;
    final key = await _db.getSetting('thegamesdb_api_key');
    if (key != null && key.isNotEmpty) {
      try {
        final meta = await TheGamesDbClient(key).search(candidate);
        if (meta != null && meta.title.isNotEmpty) resolved = meta.title;
      } catch (_) {
        // Network/API failure — fall back to the parsed candidate.
      }
    }

    setState(() => _busy = false);
    if (!mounted) return;

    // 3. Confirm / edit the title.
    final controller = TextEditingController(text: resolved);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import game'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Game title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;

    // 4. Extract.
    if (!mounted) return;
    setState(() => _busy = true);
    final result = await Importer(_libraryRoot).importZip(zip.path, title);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!mounted) return;

    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${result.error}')),
      );
      return;
    }

    // 5. Delete-check: if fully extracted, offer to delete the zip.
    if (result.fullyExtracted) {
      final delete = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete zip?'),
          content: Text(
            'Imported ${result.baseFiles} base + ${result.updateFiles} update '
            'file(s) to "$title". The zip is fully extracted — delete it to '
            'reclaim space?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (delete == true) {
        try {
          zip.deleteSync();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Zip deleted — space reclaimed.')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not delete zip: $e')),
            );
          }
        }
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Extraction incomplete — zip kept for safety.'),
          ),
        );
      }
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_current.path),
        leading: _current.path != '/storage/emulated/0'
            ? IconButton(icon: const Icon(Icons.arrow_upward), onPressed: _up)
            : null,
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                for (final d in _subdirs)
                  ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(p.basename(d.path)),
                    onTap: () => _enter(d),
                  ),
                if (_subdirs.isNotEmpty && _zips.isNotEmpty)
                  const Divider(),
                for (final z in _zips)
                  ListTile(
                    leading: const Icon(Icons.archive),
                    title: Text(p.basename(z.path)),
                    subtitle: Text(_sizeLabel(z.lengthSync())),
                    trailing: const Icon(Icons.arrow_forward),
                    onTap: () => _import(z),
                  ),
                if (_subdirs.isEmpty && _zips.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No zips in this folder')),
                  ),
              ],
            ),
    );
  }

  static String _sizeLabel(int bytes) {
    const gb = 1024 * 1024 * 1024.0, mb = 1024 * 1024.0;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(0)} MB';
    return '$bytes B';
  }
}
