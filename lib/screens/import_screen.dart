import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../config/app_paths.dart';
import '../config/supported_formats.dart';
import '../services/importer.dart';
import '../services/rom_scanner.dart';
import '../services/tag_db.dart';
import '../services/thegamesdb_client.dart';
import '../services/title_parser.dart';
import '../services/zip_classifier.dart';

/// Import flow: browse to a zip, auto-title it from TheGamesDB, extract into
/// the per-game library layout, then offer to delete the zip once fully
/// extracted (to reclaim space).
class ImportScreen extends StatefulWidget {
  const ImportScreen({super.key});

  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  final TagDb _db = TagDb();

  Directory _current = Directory(AppPaths.defaultImportRoot);
  List<Directory> _subdirs = [];
  List<File> _archives = [];
  List<File> _roms = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_isInDownloads(_current.path)) {
      _current = Directory(AppPaths.downloadsRoot);
    }
    final dirs = <Directory>[];
    final archives = <File>[];
    final roms = <File>[];
    try {
      for (final e in _current.listSync(followLinks: false)) {
        if (e is Directory) {
          dirs.add(e);
        } else if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (SupportedFormats.archives.contains(ext)) {
            archives.add(e);
          } else if (kSwitchRomExtensions.contains(ext)) {
            roms.add(e);
          }
        }
      }
    } catch (_) {
      // Unreadable dir — show empty.
    }
    dirs.sort((a, b) => a.path.compareTo(b.path));
    archives.sort((a, b) => a.path.compareTo(b.path));
    roms.sort((a, b) => a.path.compareTo(b.path));
    if (!mounted) return;
    setState(() {
      _subdirs = dirs;
      _archives = archives;
      _roms = roms;
    });
  }

  void _enter(Directory d) {
    if (!_isInDownloads(d.path)) return;
    setState(() => _current = d);
    _load();
  }

  void _up() {
    if (p.equals(p.normalize(_current.path), AppPaths.downloadsRoot)) return;
    final parent = _current.parent;
    if (!_isInDownloads(parent.path)) return;
    setState(() => _current = parent);
    _load();
  }

  /// Resolves the real game title from TheGamesDB (if a key is set), falling
  /// back to the parsed filename candidate.
  Future<String> _resolveTitle(String candidate) async {
    final key = await _db.getSetting('thegamesdb_api_key');
    if (key != null && key.isNotEmpty) {
      try {
        final meta = await TheGamesDbClient.searchOnce(key, candidate);
        if (meta != null && meta.title.isNotEmpty) return meta.title;
      } catch (_) {
        // Fall back to the parsed candidate.
      }
    }
    return candidate;
  }

  /// Resolves the target game folder for [fileName] by title ID first. Update
  /// IDs are normalized to their corresponding base-game IDs by [TagDb], so an
  /// update lands in the base's folder regardless of how their titles differ.
  /// Returns null if no title ID match is found (caller falls back to
  /// name-based resolution).
  Future<String?> _resolveTargetByTitleId(String fileName) async {
    final id = TitleParser.titleId(fileName);
    if (id == null) return null;
    final stored = await _db.folderForTitleId(id);
    if (stored != null && Directory(stored).existsSync()) return stored;

    // Older app versions did not persist IDs for every import. Inspect the
    // already-organized base filenames once, then backfill the cache.
    final discovered = RomScanner().findGameFolderByTitleId(
      Directory(AppPaths.libraryRoot),
      id,
    );
    if (discovered != null) await _db.saveTitleId(discovered, id);
    return discovered;
  }

  Future<String?> _pickExistingGameFolder() async {
    final root = Directory(AppPaths.libraryRoot);
    if (!root.existsSync()) return null;
    final games = root
        .listSync(followLinks: false)
        .whereType<Directory>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (games.isEmpty || !mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Choose the base game'),
        children: [
          for (final game in games)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, game.path),
              child: Text(p.basename(game.path)),
            ),
        ],
      ),
    );
  }

  Future<void> _autoImport() async {
    // Show the spinner immediately — the scan below can take seconds on a
    // large folder, and without this the button looks dead during it.
    setState(() => _busy = true);
    var imported = 0, skipped = 0, warnings = 0;
    try {
      final currentPath = _current.path;
      final files = await Isolate.run(
        () => RomScanner().findImportables(
          Directory(currentPath),
          excludedRoots: const {AppPaths.managerRoot},
        ),
      );
      if (!mounted) return;
      if (files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No Switch ROMs or archives found here.')),
          );
        }
        return;
      }

      // Ask once up front whether to delete fully-extracted archives. This is a
      // destructive action (deletes the user's original zips), so it must be
      // confirmed — not done silently in a bulk loop.
      final hasArchive = files.any((f) =>
          SupportedFormats.archives.contains(p.extension(f).toLowerCase()));
      var deleteArchives = false;
      if (hasArchive) {
        deleteArchives = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Delete extracted archives?'),
                content: const Text(
                  'After a zip/archive is fully extracted, delete it to reclaim '
                  'space? This removes the original archive files.',
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
            ) ??
            false;
        if (!mounted) return;
      }

      final importer = Importer(AppPaths.libraryRoot);
      for (final path in files) {
        final ext = p.extension(path).toLowerCase();
        // 7z/rar can't be decoded in-app — skip them (user extracts via built-in).
        if (ext == '.7z' || ext == '.rar') {
          skipped++;
          continue;
        }
        final isArchive = SupportedFormats.archives.contains(ext);
        final title = await _resolveTitle(TitleParser.clean(p.basename(path)));
        // Match by title ID first (update IDs normalize to their base IDs).
        final target = await _resolveTargetByTitleId(p.basename(path));

        final result = isArchive
            ? await importer.importArchive(path, title, targetFolder: target)
            : await importer.importFile(path, title, targetFolder: target);
        if (result.error == null) {
          imported++;
          if (result.warning != null) warnings++;
          // Store the title ID on the base folder so future updates can match.
          if (result.baseFiles > 0) {
            final id = result.titleId ?? TitleParser.titleId(p.basename(path));
            if (id != null) await _db.saveTitleId(result.gameFolder, id);
          }
          // Delete the archive only if the user chose to.
          if (isArchive && result.fullyExtracted && deleteArchives) {
            try {
              File(path).deleteSync();
            } catch (_) {
              // Non-fatal — leave the archive.
            }
          }
        } else {
          skipped++;
        }
      }
    } finally {
      // Always clear the busy flag so the button can't get stuck disabled.
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Imported $imported, skipped $skipped.'
          '${warnings > 0 ? ' $warnings original file(s) must be deleted manually.' : ''}',
        ),
      ),
    );
    _load();
  }

  Future<void> _import(File file, {required bool isArchive}) async {
    // 7z/rar can't be decoded in-app (no decoder). Guide the user to extract
    // it with Android's built-in extractor, then import the extracted ROM.
    final ext = p.extension(file.path).toLowerCase();
    if (isArchive && (ext == '.7z' || ext == '.rar')) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Extract the archive first'),
            content: const Text(
              '7z and rar files can\'t be opened in-app. Use your device\'s '
              'built-in file manager to extract this archive, then import the '
              'extracted .nsp/.xci file from the folder it lands in.',
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
      return;
    }

    setState(() => _busy = true);

    // 1. Candidate title from the filename, resolved via TheGamesDB.
    final resolved = await _resolveTitle(TitleParser.clean(p.basename(file.path)));

    if (!mounted) return;
    setState(() => _busy = false);

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
    controller.dispose();
    if (title == null || title.isEmpty) return;

    // 4. Import: extract a zip, or move a loose ROM. Match by title ID first;
    //    update IDs normalize to their base IDs so the update lands correctly.
    if (!mounted) return;
    setState(() => _busy = true);
    final importer = Importer(AppPaths.libraryRoot);
    ImportResult result;
    try {
      var target = await _resolveTargetByTitleId(p.basename(file.path));
      final kind = ZipClassifier.classifyPath(p.basename(file.path));
      if (!isArchive && target == null && kind != RomEntryKind.base) {
        target = await _pickExistingGameFolder();
        if (target == null) return;
      }
      result = isArchive
          ? await importer.importArchive(file.path, title, targetFolder: target)
          : await importer.importFile(file.path, title, targetFolder: target);
    } finally {
      // Always clear the busy flag so the button can't get stuck disabled.
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${result.error}')),
      );
      return;
    }

    if (result.warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.warning!)),
      );
    }

    // Store the title ID on the base folder so future updates can match.
    if (result.baseFiles > 0) {
      final id = result.titleId ?? TitleParser.titleId(p.basename(file.path));
      if (id != null) await _db.saveTitleId(result.gameFolder, id);
    }
    if (!mounted) return;

    // 5. For archives only: if fully extracted, offer to delete the archive to
    //    reclaim space. Loose ROMs are moved (not copied), so nothing to delete.
    if (isArchive && result.fullyExtracted) {
      final delete = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Delete archive?'),
          content: Text(
            'Imported ${result.baseFiles} base + ${result.updateFiles} update '
            'file(s) to "$title". The archive is fully extracted — delete it '
            'to reclaim space?',
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
          file.deleteSync();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Archive deleted — space reclaimed.')),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Could not delete archive: $e')),
            );
          }
        }
      }
    } else if (isArchive) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Extraction incomplete — archive kept for safety.'),
          ),
        );
      }
    } else if (result.warning == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ROM imported successfully.')),
      );
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_current.path),
        leading: !p.equals(p.normalize(_current.path), AppPaths.downloadsRoot)
            ? IconButton(icon: const Icon(Icons.arrow_upward), onPressed: _up)
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _autoImport,
        icon: const Icon(Icons.auto_awesome),
        label: const Text('Scan & import'),
        tooltip: 'Scan this folder and import all Switch ROMs',
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
                if (_subdirs.isNotEmpty && (_archives.isNotEmpty || _roms.isNotEmpty))
                  const Divider(),
                for (final z in _archives)
                  ListTile(
                    leading: const Icon(Icons.archive),
                    title: Text(p.basename(z.path)),
                    subtitle: Text(_sizeLabel(z.lengthSync())),
                    trailing: const Icon(Icons.arrow_forward),
                    onTap: () => _import(z, isArchive: true),
                  ),
                for (final r in _roms)
                  ListTile(
                    leading: const Icon(Icons.videogame_asset),
                    title: Text(p.basename(r.path)),
                    subtitle: Text(_sizeLabel(r.lengthSync())),
                    trailing: const Icon(Icons.arrow_forward),
                    onTap: () => _import(r, isArchive: false),
                  ),
                if (_subdirs.isEmpty && _archives.isEmpty && _roms.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: Text('No archives or ROMs in this folder')),
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

  static bool _isInDownloads(String candidate) {
    final path = p.normalize(p.absolute(candidate));
    final root = p.normalize(p.absolute(AppPaths.downloadsRoot));
    return p.equals(path, root) || p.isWithin(root, path);
  }
}
