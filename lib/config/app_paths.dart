/// Android storage locations used by the application.
///
/// ## Single-user-profile assumption
///
/// These paths are hardcoded to the **primary Android user profile**
/// (`userId == 0`), whose external storage is mounted at
/// `/storage/emulated/0`. On secondary user profiles (work profiles, guest
/// users, and multi-user devices) the same volume is mounted under a
/// per-user prefix instead, i.e. `/storage/<userId>/emulated/0/...` with
/// `userId` typically 10 or 11. The app currently targets user 0 only.
///
/// This cannot be corrected from Dart: `dart:io` exposes no API for the
/// current profile id, and the constant is a `String` path. Resolving the
/// real prefix requires a platform channel (planned, not yet implemented).
///
/// ## Known limitation with the permission gate
///
/// `MANAGE_EXTERNAL_STORAGE` is granted **per user profile**. A user on a
/// secondary profile can therefore grant "all files access" and still see
/// permission and I/O errors, because the app keeps addressing
/// `/storage/emulated/0` while its own profile's storage lives elsewhere.
/// On secondary Android user profiles the library root resolves to a
/// different physical prefix; the app currently targets user 0 only.
/// Affected users see permission errors despite granting access.
///
/// ## Why the constants are still literals
///
/// Roughly twenty call sites across `screens/` and `services/` reference
/// these constants directly. Rewriting them to accept an injected,
/// resolved root is a larger refactor that is out of scope here, so the
/// values stay fixed and the assumption is documented instead.
///
/// ## Legacy roots
///
/// [legacyLibraryRoots] and [legacyContentRoots] preserve the same
/// assumption: they are absolute paths under the same primary-profile
/// prefix and are migrated once at startup.
abstract final class AppPaths {
  /// Root of the primary profile's shared Downloads folder.
  ///
  /// Assumes the primary Android user profile (`userId == 0`); see the
  /// class documentation for the secondary-profile limitation.
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
