import 'dart:io';

import '../models/import_result.dart';

/// Subfolder names in the per-game layout: base files live in the game
/// folder root, updates in [kUpdateDir], DLC in [kDlcDir]. Single owner so a
/// layout change is one edit. Note zip_classifier.classifyPath also keys off
/// the 'update/' and 'dlc/' entry-path markers inside archives.
const String kUpdateDir = 'update';
const String kDlcDir = 'dlc';

/// Lower-cased extension of [path] including the leading dot ('' if none).
///
/// Internal helper shared by [ArchiveImporter], [RomImportService] and
/// [LibraryMaintenance]. Public only because a leading underscore would make it
/// private to this file; treat it as internal to `lib/services`.
String archiveExtOf(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i).toLowerCase();
}

/// Turns a raw exception into a message safe to show in the UI. Keeps the OS
/// error text and the offending path for filesystem failures, which is what
/// makes permission/storage problems actionable for the user.
///
/// Internal helper (see [archiveExtOf]).
String friendlyFileError(Object error) {
  if (error is FormatException) return error.message;
  if (error is FileSystemException) {
    final osMessage = error.osError?.message;
    final path = error.path;
    return [
      error.message,
      if (osMessage != null && osMessage.isNotEmpty) osMessage,
      if (path != null && path.isNotEmpty) path,
    ].join(' — ');
  }
  return error.toString();
}

/// A failed [ImportResult] for [gameFolder] carrying [message] and zero file
/// counters. Internal helper (see [archiveExtOf]).
ImportResult importError(String gameFolder, String message) => ImportResult(
  gameFolder: gameFolder,
  baseFiles: 0,
  updateFiles: 0,
  dlcFiles: 0,
  fullyExtracted: false,
  error: message,
);
