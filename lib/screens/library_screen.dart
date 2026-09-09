import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/emulator_launcher.dart';
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

  /// True if a game folder has no files anywhere (base, update/, dlc/).
  bool _isEmptyFolder(Directory dir) {
    for (final e in dir.listSync(followLinks: false)) {
      if (e is File) return false;
      if (e is Directory) {
        final sub = p.basename(e.path);
        if (sub == 'update' || sub == 'dlc') {
          if (e.listSync(followLinks: false).any((f) => f is File)) return false;
        }
      }
    }
    return true;
  }

  /// Deletes every game folder that contains no files (empty shells left over
  /// from title splits or failed extractions). Never touches a folder with
  /// any file in it, so real games are safe.
  Future<void> _cleanupEmpty() async {
    final empty = _games.where(_isEmptyFolder).toList();
    if (empty.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No empty folders to clean up.')),
        );
      }
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove empty folders?'),
        content: Text(
          '${empty.length} folder(s) contain no game files and will be '
          'removed. This only deletes empty folders — no game files are '
          'touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    for (final d in empty) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {
        // Skip folders that fail to delete.
      }
    }
    _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed ${empty.length} empty folder(s).')),
      );
    }
  }

  /// Runs library maintenance: deletes old update files (keeping the latest
  /// version per game) and reports which games are missing an update.
  Future<void> _maintain() async {
    final importer = Importer(_libraryRoot);
    var deleted = 0;
    for (final g in _games) {
      deleted += importer.deleteOldUpdates(g.path);
    }
    final missing = importer.findMissingUpdates();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          deleted > 0
              ? 'Deleted $deleted old update file(s).'
              : 'No old updates to delete.',
        ),
      ),
    );
    if (missing.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Missing updates'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text('These games have a base file but no update:'),
                const SizedBox(height: 8),
                for (final m in missing)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.system_update_alt),
                    title: Text(p.basename(m)),
                  ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    _load();
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
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'Remove empty folders',
            onPressed: _cleanupEmpty,
          ),
          IconButton(
            icon: const Icon(Icons.system_update_alt),
            tooltip: 'Delete old updates + find missing',
            onPressed: _maintain,
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

class _GameDetail extends StatefulWidget {
  final Directory game;
  const _GameDetail({required this.game});

  @override
  State<_GameDetail> createState() => _GameDetailState();
}

class _GameDetailState extends State<_GameDetail> {
  late Directory game = widget.game;

  /// Renames the game folder (and its cover cache key) to a corrected title.
  Future<void> _rename() async {
    final controller = TextEditingController(text: p.basename(game.path));
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename game'),
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
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == p.basename(game.path)) {
      return;
    }

    final newPath = p.join(p.dirname(game.path), newName);
    try {
      // Move the cover cache key along with the folder.
      final db = TagDb();
      final cover = await db.getSetting('cover:${game.path}');
      game.renameSync(newPath);
      if (cover != null) {
        await db.saveSetting('cover:$newPath', cover);
        await db.saveSetting('cover:${game.path}', '');
      }
      if (!mounted) return;
      setState(() => game = Directory(newPath));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game renamed.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }
  }

  /// Launches the game's base ROM in an installed emulator.
  Future<void> _launch() async {
    // Find the first base ROM file in the game folder.
    File? rom;
    for (final e in game.listSync(followLinks: false)) {
      if (e is File) {
        rom = e;
        break;
      }
    }
    if (rom == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No base ROM file to launch.')),
        );
      }
      return;
    }

    // Detect installed emulators and show an in-app chooser.
    final emulators = await EmulatorLauncher.listEmulators();
    if (!mounted) return;

    Emulator? pick;
    if (emulators.isNotEmpty) {
      pick = await showDialog<Emulator>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('Open in emulator'),
          children: [
            for (final e in emulators)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, e),
                child: Row(
                  children: [
                    const Icon(Icons.videogame_asset),
                    const SizedBox(width: 12),
                    Text(e.label),
                  ],
                ),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Other…'),
            ),
          ],
        ),
      );
    }

    final ok = await EmulatorLauncher.launch(rom.path, emulator: pick);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not launch. Install a Switch emulator (e.g. Yuzu, Sudachi) '
            'and try again.',
          ),
        ),
      );
    }
  }

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
      appBar: AppBar(
        title: Text(p.basename(game.path)),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_circle),
            tooltip: 'Open in emulator',
            onPressed: _launch,
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Rename game',
            onPressed: _rename,
          ),
        ],
      ),
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
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.folder_off, size: 48, color: Colors.grey),
                  const SizedBox(height: 12),
                  const Text(
                    'This folder has no game files.',
                    style: TextStyle(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'It\'s an empty shell — likely left over when a game\'s '
                    'base and update were split into differently-titled '
                    'folders. Your ROM files are safe in another folder.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      try {
                        game.deleteSync(recursive: true);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Empty folder removed.')),
                          );
                          Navigator.pop(context);
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Could not remove: $e')),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.cleaning_services),
                    label: const Text('Remove this empty folder'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
