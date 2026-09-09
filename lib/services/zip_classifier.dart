import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Classification of a single entry inside a game zip.
enum RomEntryKind { base, update, dlc, other }

/// A classified entry inside a game archive.
class ZipEntryInfo {
  final String archivePath; // path inside the zip
  final String fileName; // basename
  final RomEntryKind kind;
  const ZipEntryInfo({
    required this.archivePath,
    required this.fileName,
    required this.kind,
  });
}

/// Inspects a zip's contents and classifies each entry as base game, update,
/// or DLC based on filename markers and folder structure.
class ZipClassifier {
  static const _updateMarkers = [
    'update', 'upd', 'patch', 'v1.', 'v2.', 'v3.', 'v4.', 'v5.',
  ];
  static const _dlcMarkers = ['dlc', 'addon', 'add-on', 'expansion'];

  /// Lists and classifies the entries of [zipBytes] (a decoded zip archive).
  /// Returns null if the bytes are not a valid zip.
  static List<ZipEntryInfo>? classify(Uint8List zipBytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes, verify: false);
    } catch (_) {
      return null;
    }
    if (archive.isEmpty) return null; // garbage bytes decode to an empty archive
    final out = <ZipEntryInfo>[];
    for (final f in archive.files) {
      if (f.isFile) {
        out.add(ZipEntryInfo(
          archivePath: f.name,
          fileName: _basename(f.name),
          kind: classifyPath(f.name),
        ));
      }
    }
    return out;
  }

  /// Classifies a single archive path as base / update / dlc.
  static RomEntryKind classifyPath(String path) {
    final lower = path.toLowerCase();
    final name = _basename(lower);

    // An "update/" folder in the zip is a strong signal.
    if (lower.contains('/update/') || lower.startsWith('update/')) {
      return RomEntryKind.update;
    }
    if (lower.contains('/dlc/') || lower.startsWith('dlc/')) {
      return RomEntryKind.dlc;
    }

    // Filename markers.
    if (_dlcMarkers.any((m) => name.contains(m))) {
      return RomEntryKind.dlc;
    }
    if (_updateMarkers.any((m) => name.contains(m))) {
      return RomEntryKind.update;
    }
    return RomEntryKind.base;
  }

  static String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }
}
