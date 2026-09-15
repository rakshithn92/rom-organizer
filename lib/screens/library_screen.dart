import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../config/app_paths.dart';
import '../services/file_mover.dart';
import '../services/import_utils.dart';
import '../services/importer.dart';
import '../services/safe_paths.dart';
import '../services/tag_db.dart';
import '../services/thegamesdb_client.dart';

/// True if [dir] contains any file anywhere, recursively. A folder is only
/// "empty" when this returns false, so real ROMs in non-standard subdirs are
/// never mistaken for empty shells.
bool _dirHasAnyFileRecursive(Directory dir) {
  if (!dir.existsSync()) return false;
  for (final e in dir.listSync(followLinks: false)) {
    if (e is File) return true;
    if (e is Directory && _dirHasAnyFileRecursive(e)) return true;
  }
  return false;
}

/// Library view: lists the organized per-game folders under the library root,
/// with cover art (from TheGamesDB) and the update/ subfolder count.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TagDb _db = TagDb();

  /// Library root of the profile the app runs in. Starts at the
  /// primary-profile default and is replaced by the resolved root before the
  /// first load completes.
  String _libraryRoot = AppPaths.libraryRoot;

  List<Directory> _games = [];
  Map<String, String> _covers = {}; // game folder path -> boxart url
  bool _loading = true;
  /// True while a destructive library operation (merge, cleanup, maintain) or
  /// a reload is running. Gates the appbar actions so destructive operations
  /// can never overlap on the same folders.
  bool _busy = false;
  bool _mergeMode = false;
  final Set<String> _selected = {}; // paths selected for merge
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _resolveRoots();
  }

  /// Resolves the profile's storage roots (memoized, so this is a no-op after
  /// the first screen) and only then lists the library.
  Future<void> _resolveRoots() async {
    final paths = await AppPaths.load();
    if (!mounted) return;
    _libraryRoot = paths.libraryRoot;
    await _load();
  }

  /// Empty-string sentinel stored under `cover:<path>` once a search has
  /// definitively found no cover, so later loads skip that game.
  static const String _noCover = '';
  /// How many cover lookups may be in flight at once (TheGamesDB allows a
  /// handful of parallel requests; more just invites rate limiting).
  static const int _coverWorkers = 4;

  Future<void> _load() async {
    if (!mounted) return;
    final gen = ++_loadGeneration;
    setState(() {
      _loading = true;
      _busy = true;
    });
    try {
      final root = Directory(_libraryRoot);
      final games = <Directory>[];
      if (root.existsSync()) {
        for (final e in root.listSync(followLinks: false)) {
          if (e is Directory) games.add(e);
        }
      }
      games.sort((a, b) => a.path.compareTo(b.path));

      // Cached covers come from local SQLite, so they resolve fast enough to
      // show the library immediately; only the network lookups below are slow.
      final covers = <String, String>{};
      final uncached = <Directory>[];
      for (final g in games) {
        final cached = await _db.getSetting('cover:${g.path}');
        if (cached == null) {
          uncached.add(g);
        } else {
          covers[g.path] = cached;
        }
      }

      if (gen != _loadGeneration || !mounted) return;
      setState(() {
        _games = games;
        _covers = covers;
        _loading = false;
      });

      if (uncached.isEmpty) return;
      final key = await _db.getSetting('thegamesdb_api_key');
      if (key == null || key.isEmpty) return;

      // Fetch the missing covers with a small worker pool instead of one long
      // serial loop, patching the grid after each one lands.
      var next = 0;
      Future<void> worker() async {
        while (true) {
          if (gen != _loadGeneration || !mounted) return;
          final i = next++;
          if (i >= uncached.length) return;
          final path = uncached[i].path;
          String? url;
          try {
            final meta = await TheGamesDbClient.searchOnce(
              key,
              p.basename(path),
            );
            url = meta?.boxartUrl;
          } on TheGamesDbException {
            // Rate limited / rejected: leave uncached so the next load retries.
            continue;
          } catch (_) {
            // Network failure: also retry next load.
            continue;
          }
          if (gen != _loadGeneration || !mounted) return;
          // A null boxart is a definitive "no cover" — remember it so the next
          // load doesn't search this game again.
          final value = url ?? _noCover;
          await _db.saveSetting('cover:$path', value);
          if (gen != _loadGeneration || !mounted) return;
          setState(() => _covers[path] = value);
        }
      }

      await Future.wait(
        List.generate(
          _coverWorkers < uncached.length ? _coverWorkers : uncached.length,
          (_) => worker(),
        ),
      );
    } finally {
      if (mounted && gen == _loadGeneration) setState(() => _busy = false);
    }
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

    // Merging moves files out of the source folders and deletes them — a
    // destructive action that must be confirmed.
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Merge folders?'),
        content: Text(
          'Move all files from ${sources.length} folder(s) into '
          '"${p.basename(target.path)}"? The source folders will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    final int moved;
    try {
      moved = await Isolate.run(
        () => Importer(_libraryRoot).mergeGames(target.path, sources),
      );
      if (!mounted) return;
      // Remove the cover + title-ID cache keys for the merged-away source
      // folders, but first carry a source title-ID onto the target if it has
      // none yet.
      final db = _db;
      String? capturedTitleId;
      for (final s in sources) {
        capturedTitleId ??= await db.titleIdForFolder(s);
      }
      if (capturedTitleId != null &&
          await db.titleIdForFolder(target.path) == null) {
        await db.saveTitleId(target.path, capturedTitleId);
      }
      for (final s in sources) {
        await db.deleteSetting('cover:$s');
        await db.deleteTitleId(s);
      }
      if (!mounted) return;
      setState(() {
        _mergeMode = false;
        _selected.clear();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Merged $moved file(s) into ${p.basename(target.path)}.')),
      );
    }
  }

  /// True if a game folder has no files anywhere (base, update/, dlc/, or any
  /// other subdirectory). A folder with ANY file in ANY subfolder is NOT empty
  /// — otherwise cleanup could delete real ROMs in a non-standard subdir.
  bool _isEmptyFolder(Directory dir) => !_dirHasAnyFileRecursive(dir);

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
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    final int removed;
    try {
      // Deleting recursive folder trees blocks for however long the FS takes,
      // so it runs off the UI isolate. Only the folder paths cross over.
      final folderPaths = empty.map((d) => d.path).toList();
      removed = await Isolate.run(() {
        var count = 0;
        for (final path in folderPaths) {
          try {
            final dir = Directory(path);
            if (!dir.existsSync()) continue; // already gone: nothing to remove
            // Re-check inside the isolate: a file may have appeared since the
            // emptiness scan, and a folder with any file must never be deleted.
            if (_dirHasAnyFileRecursive(dir)) continue;
            dir.deleteSync(recursive: true);
            // Count the folder as removed only once it is actually gone, so a
            // delete that fails does not inflate the reported count.
            if (!dir.existsSync()) count++;
          } catch (_) {
            // Skip folders that fail to delete.
          }
        }
        return count;
      });
      final db = _db;
      for (final d in empty) {
        await db.deleteSetting('cover:${d.path}');
        await db.deleteTitleId(d.path);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Removed $removed empty folder(s).')),
      );
    }
  }

  /// Runs library maintenance: deletes old update files (keeping the latest
  /// version per game) and reports which games are missing an update.
  Future<void> _maintain() async {
    // Deleting old update files is destructive — confirm first.
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete old updates?'),
        content: const Text(
          'For each game, keep only the latest update version and delete the '
          'older ones to reclaim space?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final gamePaths = _games.map((game) => game.path).toList();
      final result = await Isolate.run(() {
        final importer = Importer(_libraryRoot);
        var deleted = 0;
        for (final gamePath in gamePaths) {
          deleted += importer.deleteOldUpdates(gamePath);
        }
        return (deleted: deleted, missing: importer.findMissingUpdates());
      });
      final deleted = result.deleted;
      final missing = result.missing;
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await _load();
  }

  /// Cached cover lookup. The [_noCover] sentinel means "known to have no
  /// cover" and maps to null so the card shows its placeholder icon.
  String? _coverFor(String path) {
    final url = _covers[path];
    return (url == null || url.isEmpty) ? null : url;
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
              onPressed: _busy ? null : () => setState(() => _mergeMode = true),
            ),
          IconButton(
            icon: const Icon(Icons.cleaning_services),
            tooltip: 'Remove empty folders',
            onPressed: _busy ? null : _cleanupEmpty,
          ),
          IconButton(
            icon: const Icon(Icons.system_update_alt),
            tooltip: 'Delete old updates + find missing',
            onPressed: _busy ? null : _maintain,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _busy ? null : _load,
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
                          coverUrl: _coverFor(_games[i].path),
                          mergeMode: _mergeMode,
                          selected: _selected.contains(_games[i].path),
                          onTap: _mergeMode
                              ? () => setState(() {
                                    if (!_selected.add(_games[i].path)) {
                                      _selected.remove(_games[i].path);
                                    }
                                  })
                              : () async {
                                  final changed = await Navigator.push<bool>(
                                    ctx,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          _GameDetail(game: _games[i]),
                                    ),
                                  );
                                  if (changed == true && mounted) {
                                    unawaited(_load());
                                  }
                                },
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
    final hasUpdate = Directory(p.join(game.path, kUpdateDir)).existsSync();
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
                      ? Image.network(
                          coverUrl!,
                          fit: BoxFit.cover,
                          loadingBuilder: (ctx, child, progress) =>
                              progress == null
                                  ? child
                                  : const ColoredBox(
                                      color: Colors.black26,
                                      child: Center(
                                          child: CircularProgressIndicator()),
                                    ),
                          errorBuilder: (ctx, error, stack) => const ColoredBox(
                            color: Colors.black26,
                            child: Center(
                                child: Icon(Icons.videogame_asset, size: 40)),
                          ),
                        )
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
  final TagDb _db = TagDb();

  late Directory game = widget.game;
  String? _titleId;

  @override
  void initState() {
    super.initState();
    _loadTitleId();
  }

  Future<void> _loadTitleId() async {
    final tid = await _db.titleIdForFolder(game.path);
    if (mounted) setState(() => _titleId = tid);
  }

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
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == p.basename(game.path)) {
      return;
    }

    late final String newPath;
    try {
      newPath = SafePaths.existingGameFolder(
        p.dirname(game.path),
        p.join(p.dirname(game.path), Importer.sanitizeFolderName(newName)),
      );
      if (Directory(newPath).existsSync()) {
        throw FileSystemException(
          'A game folder with that name already exists. Use Merge instead.',
          newPath,
        );
      }
      // Move the cover cache key along with the folder.
      final db = _db;
      final cover = await db.getSetting('cover:${game.path}');
      // Move off the UI isolate; cross-volume moves safely fall back to a
      // recursive copy while retaining the source if that copy fails.
      await Isolate.run(() => FileMover.moveDirectory(game.path, newPath));
      if (cover != null) {
        await db.saveSetting('cover:$newPath', cover);
        await db.deleteSetting('cover:${game.path}');
      }
      // Move the title-ID key along with the folder.
      final tid = await db.titleIdForFolder(game.path);
      if (tid != null) {
        await db.saveTitleId(newPath, tid);
        await db.deleteTitleId(game.path);
      }
      if (!mounted) return;
      setState(() => game = Directory(newPath));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Game renamed.')),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = <File>[];
    final updateFiles = <File>[];
    final dlcFiles = <File>[];
    final exists = game.existsSync();
    if (exists) {
      for (final e in game.listSync(followLinks: false)) {
        if (e is File) files.add(e);
      }
    }
    final updateDir = Directory(p.join(game.path, kUpdateDir));
    if (updateDir.existsSync()) {
      for (final e in updateDir.listSync(followLinks: false)) {
        if (e is File) updateFiles.add(e);
      }
    }
    final dlcDir = Directory(p.join(game.path, kDlcDir));
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
            icon: const Icon(Icons.edit),
            tooltip: 'Rename game',
            onPressed: _rename,
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_titleId != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.tag),
              title: Text('Title ID: $_titleId'),
              subtitle: const Text(
                  'Used to match updates to this game. If blank, no title ID '
                  'was found in the filename.'),
            ),
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
          if (!_dirHasAnyFileRecursive(game))
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
                      // Capture context-dependent objects before the await.
                      final messenger = ScaffoldMessenger.of(context);
                      final navigator = Navigator.of(context);
                      final path = game.path;
                      try {
                        // Recursive delete can block on slow storage — keep it
                        // off the UI isolate.
                        final removed = await Isolate.run(() {
                          final dir = Directory(path);
                          if (_dirHasAnyFileRecursive(dir)) return false;
                          if (dir.existsSync()) dir.deleteSync(recursive: true);
                          return true;
                        });
                        if (!removed) {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Folder now contains files — not removing.',
                              ),
                            ),
                          );
                          return;
                        }
                        final db = _db;
                        await db.deleteSetting('cover:$path');
                        await db.deleteTitleId(path);
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Empty folder removed.')),
                        );
                        navigator.pop(true);
                      } catch (e) {
                        messenger.showSnackBar(
                          SnackBar(content: Text('Could not remove: $e')),
                        );
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
