import 'dart:io';

import 'package:path/path.dart' as p;

import '../config/supported_formats.dart';
import '../models/rom_file.dart';
import 'title_parser.dart';

export '../models/rom_file.dart';

/// Recognized Nintendo Switch ROM container extensions.
const Set<String> kSwitchRomExtensions = SupportedFormats.switchRoms;

/// Scans a directory for Switch ROM files (non-recursive by default).
class RomScanner {
  /// Returns the ROM files directly inside [dir]. When [recursive] is true,
  /// descends into subdirectories. Non-ROM files are ignored.
  List<RomFile> scan(Directory dir, {bool recursive = false}) {
    final out = <RomFile>[];
    if (!dir.existsSync()) return out;
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return out;
    }
    for (final e in entries) {
      if (e is File) {
        final ext = _ext(e.path);
        if (kSwitchRomExtensions.contains(ext)) {
          final stat = e.statSync();
          out.add(RomFile(
            path: e.path,
            name: p.basename(e.path),
            baseName: _base(e.path),
            extension: ext,
            sizeBytes: stat.size,
            modified: stat.modified,
          ));
        }
      } else if (e is Directory && recursive) {
        out.addAll(scan(e, recursive: true));
      }
    }
    return out;
  }

  /// Recursively finds every importable file under [dir]: loose Switch ROMs
  /// AND archives (zip/tar/gz/bz2/xz). Returns absolute paths.
  List<String> findImportables(
    Directory dir, {
    Set<String> excludedRoots = const {},
  }) {
    final out = <String>[];
    if (!dir.existsSync()) return out;
    final normalizedDir = p.normalize(p.absolute(dir.path));
    if (excludedRoots.any(
      (root) => normalizedDir == p.normalize(p.absolute(root)),
    )) {
      return out;
    }
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return out;
    }
    for (final e in entries) {
      if (e is File) {
        final ext = _ext(e.path);
        if (kSwitchRomExtensions.contains(ext) ||
            SupportedFormats.archives.contains(ext)) {
          out.add(e.path);
        }
      } else if (e is Directory) {
        out.addAll(findImportables(e, excludedRoots: excludedRoots));
      }
    }
    return out;
  }

  /// Finds an existing game folder by inspecting the title IDs of its base
  /// files. This is a fallback for libraries created before title IDs were
  /// persisted in the database.
  String? findGameFolderByTitleId(Directory libraryRoot, String titleId) {
    if (!libraryRoot.existsSync()) return null;
    final wanted = TitleParser.canonicalBaseTitleId(titleId);
    final List<FileSystemEntity> games;
    try {
      games = libraryRoot.listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    for (final game in games) {
      if (game is! Directory) continue;
      final List<FileSystemEntity> entries;
      try {
        entries = game.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entry in entries) {
        if (entry is! File ||
            !kSwitchRomExtensions.contains(_ext(entry.path))) {
          continue;
        }
        final candidate = TitleParser.titleId(p.basename(entry.path));
        if (candidate != null &&
            !TitleParser.isUpdateTitleId(candidate) &&
            TitleParser.canonicalBaseTitleId(candidate) == wanted) {
          return game.path;
        }
      }
    }
    return null;
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i).toLowerCase();
  }

  static String _base(String path) {
    final name = p.basename(path);
    final i = name.lastIndexOf('.');
    return i < 0 ? name : name.substring(0, i);
  }
}
