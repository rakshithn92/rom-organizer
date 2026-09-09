import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/importer.dart';
import '../services/rom_scanner.dart';
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
  static const _defaultStart = '/storage/emulated/0/Download';
  final TagDb _db = TagDb();

  Directory _current = Directory(_defaultStart);
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
    final dirs = <Directory>[];
    final archives = <File>[];
    final roms = <File>[];
    try {
      for (final e in _current.listSync(followLinks: false)) {
        if (e is Directory) {
          dirs.add(e);
        } else if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (kArchiveExtensions.contains(ext)) {
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
    setState(() => _current = d);
    _load();
  }

  void _up() {
    final parent = _current.parent;
    if (parent.path == _current.path) return;
    setState(() => _current = parent);
    _load();
  }

  /// Recursively scans the current folder for Switch ROMs and archives and
  /// imports each one, auto-titling from TheGamesDB. Skips files that fail
  /// validation (e.g. a zip with no Switch ROM inside).
  Future<void> _autoImport() async {
    final files = RomScanner().findImportables(_current);
    if (files.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No Switch ROMs or archives found here.')),
        );
      }
      return;
    }

    setState(() => _busy = true);
    final importer = Importer(_libraryRoot);
    var imported = 0, skipped = 0;
    for (final path in files) {
      final ext = p.extension(path).toLowerCase();
      // 7z/rar can't be decoded in-app — skip them (user extracts via built-in).
      if (ext == '.7z' || ext == '.rar') {
        skipped++;
        continue;
      }
      final isArchive = kArchiveExtensions.contains(ext);
      final candidate = TitleParser.clean(p.basename(path));

      // Resolve the real title from TheGamesDB (if a key is set).
      var title = candidate;
      final key = await _db.getSetting('thegamesdb_api_key');
      if (key != null && key.isNotEmpty) {
        try {
          final meta = await TheGamesDbClient(key).search(candidate);
          if (meta != null && meta.title.isNotEmpty) title = meta.title;
        } catch (_) {
          // Fall back to the parsed candidate.
        }
      }

      final result = isArchive
          ? await importer.importArchive(path, title)
          : await importer.importFile(path, title);
      if (result.error == null) {
        imported++;
        // If it was an archive and fully extracted, delete it to reclaim space.
        if (isArchive && result.fullyExtracted) {
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

    setState(() => _busy = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Imported $imported, skipped $skipped.'),
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

    // 1. Candidate title from the filename.
    final candidate = TitleParser.clean(p.basename(file.path));

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

    // 4. Import: extract a zip, or move a loose ROM.
    if (!mounted) return;
    setState(() => _busy = true);
    final importer = Importer(_libraryRoot);
    final result = isArchive
        ? await importer.importArchive(file.path, title)
        : await importer.importFile(file.path, title);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!mounted) return;

    if (result.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${result.error}')),
      );
      return;
    }

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
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Extraction incomplete — archive kept for safety.'),
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
}
