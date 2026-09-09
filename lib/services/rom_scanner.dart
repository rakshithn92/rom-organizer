import 'dart:io';

import 'package:path/path.dart' as p;

/// Recognized Nintendo Switch ROM container extensions.
const Set<String> kSwitchRomExtensions = {
  '.nsp', '.xci', '.nsz', '.xcz', '.nca',
};

/// A single ROM file discovered on disk.
class RomFile {
  final String path;
  final String name; // file name with extension
  final String baseName; // file name without extension
  final String extension; // lowercased, with dot, e.g. '.nsp'
  final int sizeBytes;
  final DateTime modified;

  const RomFile({
    required this.path,
    required this.name,
    required this.baseName,
    required this.extension,
    required this.sizeBytes,
    required this.modified,
  });

  String get sizeLabel {
    const kb = 1024.0, mb = kb * 1024, gb = mb * 1024;
    if (sizeBytes >= gb) return '${(sizeBytes / gb).toStringAsFixed(1)} GB';
    if (sizeBytes >= mb) return '${(sizeBytes / mb).toStringAsFixed(0)} MB';
    if (sizeBytes >= kb) return '${(sizeBytes / kb).toStringAsFixed(0)} KB';
    return '$sizeBytes B';
  }
}

/// Scans a directory for Switch ROM files (non-recursive by default).
class RomScanner {
  /// Returns the ROM files directly inside [dir]. When [recursive] is true,
  /// descends into subdirectories. Non-ROM files are ignored.
  List<RomFile> scan(Directory dir, {bool recursive = false}) {
    final out = <RomFile>[];
    if (!dir.existsSync()) return out;
    for (final e in dir.listSync(followLinks: false)) {
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
