import 'dart:io';

import 'package:flutter/material.dart';

import '../services/rom_scanner.dart';
import '../services/tag_db.dart';
import 'settings_screen.dart';

/// Sort order for the ROM list.
enum RomSort { name, size, modified }

/// Main browser: navigate folders, list Switch ROMs, sort, rename, tag.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final TagDb _db = TagDb();
  final RomScanner _scanner = RomScanner();

  Directory _current = Directory('/storage/emulated/0');
  List<Directory> _subdirs = [];
  List<RomFile> _roms = [];
  Map<String, List<String>> _tags = {};
  RomSort _sort = RomSort.name;
  bool _ascending = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final dirs = <Directory>[];
    try {
      for (final e in _current.listSync(followLinks: false)) {
        if (e is Directory) dirs.add(e);
      }
    } catch (_) {
      // Unreadable dir — show empty.
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));

    final roms = _scanner.scan(_current);
    _sortRoms(roms);

    // Load tags for the visible ROMs.
    final tags = <String, List<String>>{};
    for (final r in roms) {
      tags[r.path] = await _db.tagsFor(r.path);
    }

    if (!mounted) return;
    setState(() {
      _subdirs = dirs;
      _roms = roms;
      _tags = tags;
    });
  }

  void _sortRoms(List<RomFile> roms) {
    int cmp(RomFile a, RomFile b) {
      switch (_sort) {
        case RomSort.size:
          return a.sizeBytes.compareTo(b.sizeBytes);
        case RomSort.modified:
          return a.modified.compareTo(b.modified);
        case RomSort.name:
          return a.baseName.toLowerCase().compareTo(b.baseName.toLowerCase());
      }
    }

    roms.sort(cmp);
    if (!_ascending) roms = roms.reversed.toList();
  }

  void _enter(Directory d) {
    setState(() => _current = d);
    _load();
  }

  void _up() {
    final parent = _current.parent;
    if (parent.path == _current.path) return; // at root
    setState(() => _current = parent);
    _load();
  }

  Future<void> _rename(RomFile rom) async {
    final controller = TextEditingController(text: rom.baseName);
    final newBase = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename ROM'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'New name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newBase == null || newBase.isEmpty || newBase == rom.baseName) return;

    final newPath =
        '${_current.path}${Platform.pathSeparator}$newBase${rom.extension}';
    try {
      await File(rom.path).rename(newPath);
      await _db.moveTags(rom.path, newPath);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }
  }

  Future<void> _editTags(RomFile rom) async {
    final current = _tags[rom.path] ?? [];
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tags — ${rom.baseName}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 6,
              children: [
                for (final t in current)
                  Chip(
                    label: Text(t),
                    onDeleted: () async {
                      await _db.removeTag(rom.path, t);
                      _load();
                    },
                  ),
              ],
            ),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'Add tag'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
          FilledButton(
            onPressed: () {
              final t = controller.text.trim();
              if (t.isNotEmpty) {
                _db.addTag(rom.path, t);
                _load();
              }
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_current.path),
        leading: _current.path != '/storage/emulated/0'
            ? IconButton(icon: const Icon(Icons.arrow_upward), onPressed: _up)
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          PopupMenuButton<RomSort>(
            initialValue: _sort,
            onSelected: (s) {
              setState(() {
                if (_sort == s) {
                  _ascending = !_ascending;
                } else {
                  _sort = s;
                  _ascending = true;
                }
              });
              _load();
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: RomSort.name, child: Text('Sort by name')),
              const PopupMenuItem(value: RomSort.size, child: Text('Sort by size')),
              const PopupMenuItem(
                  value: RomSort.modified, child: Text('Sort by modified')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          children: [
            for (final d in _subdirs)
              ListTile(
                leading: const Icon(Icons.folder),
                title: Text(d.uri.pathSegments.last),
                onTap: () => _enter(d),
              ),
            if (_subdirs.isNotEmpty && _roms.isNotEmpty)
              const Divider(),
            for (final r in _roms)
              ListTile(
                leading: const Icon(Icons.videogame_asset),
                title: Text(r.baseName),
                subtitle: Text(
                  '${r.sizeLabel} · ${_tags[r.path]?.join(', ') ?? ''}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () => _rename(r),
                    ),
                    IconButton(
                      icon: const Icon(Icons.label_outline),
                      onPressed: () => _editTags(r),
                    ),
                  ],
                ),
              ),
            if (_subdirs.isEmpty && _roms.isEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('No ROMs in this folder')),
              ),
          ],
        ),
      ),
    );
  }
}
