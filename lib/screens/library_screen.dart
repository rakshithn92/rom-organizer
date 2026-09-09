import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/importer.dart';
import '../services/tag_db.dart';
import '../services/thegamesdb_client.dart';

/// Library view: lists the organized per-game folders under the library root,
/// with cover art (from TheGamesDB) and the update/ subfolder count.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  static const _libraryRoot = '/storage/emulated/0/ROMs/Switch';
  final TagDb _db = TagDb();

  List<Directory> _games = [];
  Map<String, String> _covers = {}; // game folder path -> boxart url
  bool _loading = true;
  bool _mergeMode = false;
  final Set<String> _selected = {}; // paths selected for merge

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final root = Directory(_libraryRoot);
    final games = <Directory>[];
    if (root.existsSync()) {
      for (final e in root.listSync(followLinks: false)) {
        if (e is Directory) games.add(e);
      }
    }
    games.sort((a, b) => a.path.compareTo(b.path));

    // Fetch covers for games that don't have one cached yet.
    final covers = <String, String>{};
    final key = await _db.getSetting('thegamesdb_api_key');
    for (final g in games) {
      final cached = await _db.getSetting('cover:${g.path}');
      if (cached != null) {
        covers[g.path] = cached;
      } else if (key != null && key.isNotEmpty) {
        try {
          final meta = await TheGamesDbClient(key).search(p.basename(g.path));
          if (meta?.boxartUrl != null) {
            covers[g.path] = meta!.boxartUrl!;
            await _db.saveSetting('cover:${g.path}', meta.boxartUrl!);
          }
        } catch (_) {
          // Skip on network failure.
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _games = games;
      _covers = covers;
      _loading = false;
    });
  }

  /// Merges the selected folders into [target]. The target keeps its name and
  /// cover; every file from the other selected folders is moved into it.
  Future<void> _mergeInto(Directory target) async {
    final sources = _selected.where((s) => s != target.path).toList();
    if (sources.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select at least one other folder to merge.')),
        );
      }
      return;
    }
    final moved = Importer(_libraryRoot).mergeGames(target.path, sources);
    setState(() {
      _mergeMode = false;
      _selected.clear();
    });
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Merged $moved file(s) into ${p.basename(target.path)}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_mergeMode ? 'Select folders to merge' : 'Library'),
        actions: [
          if (_mergeMode)
            TextButton(
              onPressed: () => setState(() {
                _mergeMode = false;
                _selected.clear();
              }),
              child: const Text('Cancel'),
            )
          else
            IconButton(
              icon: const Icon(Icons.merge),
              tooltip: 'Merge duplicate folders',
              onPressed: () => setState(() => _mergeMode = true),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _games.isEmpty
              ? const Center(
                  child: Text(
                    'No games yet.\nImport a zip to build your library.',
                    textAlign: TextAlign.center,
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 160,
                          childAspectRatio: 0.7,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _games.length,
                        itemBuilder: (ctx, i) => _GameCard(
                          game: _games[i],
                          coverUrl: _covers[_games[i].path],
                          mergeMode: _mergeMode,
                          selected: _selected.contains(_games[i].path),
                          onTap: _mergeMode
                              ? () => setState(() {
                                    if (!_selected.add(_games[i].path)) {
                                      _selected.remove(_games[i].path);
                                    }
                                  })
                              : null,
                        ),
                      ),
                    ),
                    if (_mergeMode)
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${_selected.length} selected. Tap a folder '
                                  'again to deselect.',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                              FilledButton(
                                onPressed: _selected.length < 2
                                    ? null
                                    : () => _pickTarget(),
                                child: const Text('Merge into…'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }

  /// After selecting folders, pick which one is the target (keeps its name).
  Future<void> _pickTarget() async {
    final target = await showDialog<Directory>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Merge into which folder?'),
        children: [
          for (final g in _games.where((g) => _selected.contains(g.path)))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Text(p.basename(g.path)),
            ),
        ],
      ),
    );
    if (target != null) await _mergeInto(target);
  }
}

class _GameCard extends StatelessWidget {
  final Directory game;
  final String? coverUrl;
  final bool mergeMode;
  final bool selected;
  final VoidCallback? onTap;
  const _GameCard({
    required this.game,
    required this.coverUrl,
    this.mergeMode = false,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasUpdate = Directory(p.join(game.path, 'update')).existsSync();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap ??
            () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => _GameDetail(game: game)),
                ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: coverUrl != null
                      ? Image.network(coverUrl!, fit: BoxFit.cover)
                      : const ColoredBox(
                          color: Colors.black26,
                          child: Center(
                              child: Icon(Icons.videogame_asset, size: 40)),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.basename(game.path),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (hasUpdate)
                        const Text(
                          'has update',
                          style: TextStyle(fontSize: 11, color: Colors.orange),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (mergeMode)
              Positioned(
                top: 4,
                right: 4,
                child: Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? Colors.green : Colors.white,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GameDetail extends StatelessWidget {
  final Directory game;
  const _GameDetail({required this.game});

  @override
  Widget build(BuildContext context) {
    final files = <File>[];
    final updateFiles = <File>[];
    final dlcFiles = <File>[];
    for (final e in game.listSync(followLinks: false)) {
      if (e is File) files.add(e);
    }
    final updateDir = Directory(p.join(game.path, 'update'));
    if (updateDir.existsSync()) {
      for (final e in updateDir.listSync(followLinks: false)) {
        if (e is File) updateFiles.add(e);
      }
    }
    final dlcDir = Directory(p.join(game.path, 'dlc'));
    if (dlcDir.existsSync()) {
      for (final e in dlcDir.listSync(followLinks: false)) {
        if (e is File) dlcFiles.add(e);
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(p.basename(game.path))),
      body: ListView(
        children: [
          if (files.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Base files',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final f in files)
              ListTile(
                leading: const Icon(Icons.videogame_asset),
                title: Text(p.basename(f.path)),
              ),
          ],
          if (updateFiles.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Updates',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final f in updateFiles)
              ListTile(
                leading: const Icon(Icons.system_update),
                title: Text(p.basename(f.path)),
              ),
          ],
          if (dlcFiles.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('DLC',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final f in dlcFiles)
              ListTile(
                leading: const Icon(Icons.add_box),
                title: Text(p.basename(f.path)),
              ),
          ],
          if (files.isEmpty && updateFiles.isEmpty && dlcFiles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Empty game folder')),
            ),
        ],
      ),
    );
  }
}
