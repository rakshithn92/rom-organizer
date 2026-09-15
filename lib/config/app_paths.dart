import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Android storage locations used by the application.
///
/// ## Per-user-profile roots
///
/// The shared-storage prefix depends on the **Android user profile** the app
/// runs in: the primary profile (`userId == 0`) is mounted at
/// `/storage/emulated/0`, while secondary profiles (work profiles, guest
/// users, multi-user devices) get their own prefix, typically
/// `/storage/<userId>` or `/storage/<volume-id>`. Addressing
/// `/storage/emulated/0` from a secondary profile therefore points at another
/// user's storage.
///
/// [load] resolves the current profile at runtime through `path_provider`; see
/// [StoragePaths] for how the platform path is turned into a shared root. The
/// constants below are the **primary-profile defaults** and remain the
/// fallback whenever the platform cannot answer (VM tests, desktop hosts, or a
/// plugin failure) — they are still correct for the primary profile.
///
/// ## Why the constants are still literals
///
/// A handful of call sites keep the constants: the fallback in [load], the
/// defaults of service constructors, and the historical legacy roots below.
/// Everything that touches the filesystem resolves [load] first. The constants
/// must stay literal — they describe the primary profile's mount point, which
/// is what makes them a valid fallback.
///
/// ## Legacy roots
///
/// [legacyLibraryRoots] and [legacyContentRoots] are migrated once at startup.
/// The `/storage/emulated/0/...` entries are the fixed primary-profile paths
/// earlier releases wrote to; they are kept verbatim (a secondary-profile user
/// simply has nothing there). The `Download/ROM` and `Download/Content`
/// entries follow the profile's Downloads root, exactly as in [StoragePaths].
abstract final class AppPaths {
  /// Root of the primary profile's shared Downloads folder.
  ///
  /// Primary Android user profile (`userId == 0`) only; [load] resolves the
  /// current profile's root instead. See the class documentation.
  static const downloadsRoot = '/storage/emulated/0/Download';
  static const managerRoot = '$downloadsRoot/ROM Manager';
  static const libraryRoot = '$managerRoot/ROMs';
  static const contentRoot = '$managerRoot/Content';
  static const defaultImportRoot = downloadsRoot;

  /// Legacy roots that were written to the primary profile only. They are not
  /// derived from the Downloads root: they are where earlier releases put the
  /// library/content, so they keep their literal primary-profile prefix.
  static const _fixedLegacyLibraryRoots = <String>[
    '/storage/emulated/0/ROMs/Switch',
    '/storage/emulated/0/ROMs',
    '/storage/emulated/0/ROM',
  ];
  static const _fixedLegacyContentRoots = <String>[
    '/storage/emulated/0/Content',
  ];

  /// Locations used by earlier releases. They are migrated once at startup.
  static const legacyLibraryRoots = <String>[
    ..._fixedLegacyLibraryRoots,
    '$downloadsRoot/ROM',
  ];
  static const legacyContentRoots = <String>[
    ..._fixedLegacyContentRoots,
    '$downloadsRoot/Content',
  ];

  /// Memoized [load] result: the platform lookup runs once per process.
  static Future<StoragePaths>? _memoized;

  /// Roots pinned by [overrideForTesting]; when set, the platform is not asked.
  static StoragePaths? _override;

  /// The storage roots of the profile the app is running in.
  ///
  /// Resolved once (the result is memoized for the process) by asking
  /// `path_provider` for this profile's Downloads directory. When the platform
  /// cannot provide it — no plugin implementation in the VM test binding, a
  /// desktop host whose Downloads folder is not Android shared storage, or a
  /// platform error — the primary-profile constants above are used unchanged.
  static Future<StoragePaths> load() {
    final override = _override;
    // Completed in the caller's zone: awaiting it must resolve on the next
    // microtask there (`pumpAndSettle` in a widget test drives that zone only).
    if (override != null) return Future<StoragePaths>.value(override);
    return _memoized ??= _resolve();
  }

  static Future<StoragePaths> _resolve() async {
    String? platformDownloads;
    try {
      platformDownloads = (await getDownloadsDirectory())?.path;
    } catch (_) {
      // Unsupported platform, missing plugin, or a platform error: the
      // primary-profile default below is still a usable root.
    }
    return StoragePaths.fromDownloadsRoot(
      StoragePaths.sharedDownloadsRootFrom(platformDownloads) ?? downloadsRoot,
    );
  }

  /// Pins the resolved roots, bypassing the platform lookup. Call
  /// [restoreForTesting] afterwards so the next [load] resolves again.
  @visibleForTesting
  static void overrideForTesting(StoragePaths paths) {
    _override = paths;
    _memoized = null;
  }

  /// Forgets the [overrideForTesting] pin (and any memoized resolution).
  @visibleForTesting
  static void restoreForTesting() {
    _override = null;
    _memoized = null;
  }
}

/// The storage roots of one Android user profile: every library path derived
/// from that profile's shared Downloads folder.
class StoragePaths {
  /// The profile's shared Downloads folder, e.g.
  /// `/storage/emulated/0/Download` (primary) or `/storage/10,13CD-8901/Download`
  /// (secondary profile).
  final String downloadsRoot;

  /// App-managed folder inside [downloadsRoot].
  final String managerRoot;

  /// Organized per-game library.
  final String libraryRoot;

  /// App-managed content (covers, markers) for [managerRoot].
  final String contentRoot;

  /// Folder the import browser opens in.
  final String defaultImportRoot;

  /// Locations used by earlier releases, migrated once at startup.
  final List<String> legacyLibraryRoots;
  final List<String> legacyContentRoots;

  const StoragePaths({
    required this.downloadsRoot,
    required this.managerRoot,
    required this.libraryRoot,
    required this.contentRoot,
    required this.defaultImportRoot,
    required this.legacyLibraryRoots,
    required this.legacyContentRoots,
  });

  /// Derives every root from [downloadsRoot] the way [AppPaths] does for the
  /// primary profile: `ROM Manager` holds the library and the content, and the
  /// legacy `ROM` / `Content` folders sit directly in Downloads.
  factory StoragePaths.fromDownloadsRoot(String downloadsRoot) {
    final managerRoot = '$downloadsRoot/ROM Manager';
    return StoragePaths(
      downloadsRoot: downloadsRoot,
      managerRoot: managerRoot,
      libraryRoot: '$managerRoot/ROMs',
      contentRoot: '$managerRoot/Content',
      defaultImportRoot: downloadsRoot,
      legacyLibraryRoots: <String>[
        ...AppPaths._fixedLegacyLibraryRoots,
        '$downloadsRoot/ROM',
      ],
      legacyContentRoots: <String>[
        ...AppPaths._fixedLegacyContentRoots,
        '$downloadsRoot/Content',
      ],
    );
  }

  /// The shared Downloads root of the profile that owns
  /// [platformDownloadsPath], or null when that path is not Android
  /// app-scoped external storage.
  ///
  /// `path_provider` answers with `getExternalFilesDirs(DIRECTORY_DOWNLOADS)`,
  /// i.e. the *app-scoped* folder of the current profile, for example
  /// `/storage/10,13CD-8901/Android/data/<pkg>/files/Download`. That is not the
  /// shared Downloads folder; the shared one is the storage prefix followed by
  /// `/Download`. Everything from `/Android/data` onwards is app-private and
  /// must be cut off. The prefix carries the profile (or the removable volume)
  /// id, which is exactly what the hardcoded `/storage/emulated/0` got wrong.
  ///
  /// A path that is already a shared root (`/storage/.../Download`) is taken
  /// as-is. Anything else — a desktop `~/Downloads`, an iOS container — has no
  /// Android shared-storage prefix and yields null, so the caller falls back to
  /// the primary-profile default.
  static String? sharedDownloadsRootFrom(String? platformDownloadsPath) {
    if (platformDownloadsPath == null || platformDownloadsPath.isEmpty) {
      return null;
    }
    // Android platform paths are POSIX regardless of the host running this.
    final path = p.posix.normalize(platformDownloadsPath);
    const appScoped = '/Android/data/';
    final cut = path.indexOf(appScoped);
    if (cut > 0) return '${path.substring(0, cut)}/Download';
    if (path.startsWith('/storage/') && path.endsWith('/Download')) return path;
    return null;
  }
}
