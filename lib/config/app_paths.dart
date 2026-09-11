/// Android storage locations used by the application.
abstract final class AppPaths {
  static const downloadsRoot = '/storage/emulated/0/Download';
  static const managerRoot = '$downloadsRoot/ROM Manager';
  static const libraryRoot = '$managerRoot/ROMs';
  static const contentRoot = '$managerRoot/Content';
  static const defaultImportRoot = downloadsRoot;

  /// Locations used by earlier releases. They are migrated once at startup.
  static const legacyLibraryRoots = <String>[
    '/storage/emulated/0/ROMs/Switch',
    '/storage/emulated/0/ROMs',
    '/storage/emulated/0/ROM',
    '$downloadsRoot/ROM',
  ];
  static const legacyContentRoots = <String>[
    '/storage/emulated/0/Content',
    '$downloadsRoot/Content',
  ];
}
