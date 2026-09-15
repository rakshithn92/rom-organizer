import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/config/app_paths.dart';

/// Tests for the runtime root resolver.
///
/// The Android-side logic is pure path arithmetic, so it is exercised here
/// with synthetic platform paths instead of a device: `path_provider` answers
/// with the *app-scoped* downloads dir of the current profile, and the shared
/// root has to be extracted from it.
void main() {
  group('sharedDownloadsRootFrom', () {
    test('extracts the shared root from an app-scoped profile path', () {
      expect(
        StoragePaths.sharedDownloadsRootFrom(
          '/storage/10,ABCD-1234/Android/data/com.rakshith.rom_organizer/'
          'files/Download',
        ),
        '/storage/10,ABCD-1234/Download',
      );
    });

    test('keeps the primary profile prefix unchanged', () {
      // The primary profile's app-scoped path yields exactly the path the
      // hardcoded constant used to assume.
      expect(
        StoragePaths.sharedDownloadsRootFrom(
          '/storage/emulated/0/Android/data/com.rakshith.rom_organizer/'
          'files/Download',
        ),
        AppPaths.downloadsRoot,
      );
    });

    test('accepts a path that is already a shared root', () {
      expect(
        StoragePaths.sharedDownloadsRootFrom('/storage/emulated/0/Download'),
        '/storage/emulated/0/Download',
      );
    });

    test('normalizes before cutting', () {
      expect(
        StoragePaths.sharedDownloadsRootFrom(
          '/storage/10,ABCD-1234//Android/data/com.rakshith.rom_organizer/'
          'files/Download/../Download/',
        ),
        '/storage/10,ABCD-1234/Download',
      );
    });

    test('rejects paths that are not Android shared storage', () {
      // Desktop/iOS answers and missing answers must fall back to the
      // primary-profile default rather than inventing a /storage prefix.
      expect(StoragePaths.sharedDownloadsRootFrom('/home/user/Downloads'), isNull);
      expect(StoragePaths.sharedDownloadsRootFrom('/tmp/x'), isNull);
      expect(StoragePaths.sharedDownloadsRootFrom(null), isNull);
      expect(StoragePaths.sharedDownloadsRootFrom(''), isNull);
    });
  });

  group('StoragePaths.fromDownloadsRoot', () {
    test('derives every root from the resolved downloads root', () {
      final paths = StoragePaths.fromDownloadsRoot('/storage/10,ABCD-1234/Download');

      expect(paths.downloadsRoot, '/storage/10,ABCD-1234/Download');
      expect(paths.managerRoot, '/storage/10,ABCD-1234/Download/ROM Manager');
      expect(paths.libraryRoot, '/storage/10,ABCD-1234/Download/ROM Manager/ROMs');
      expect(paths.contentRoot, '/storage/10,ABCD-1234/Download/ROM Manager/Content');
      expect(paths.defaultImportRoot, paths.downloadsRoot);
    });

    test('matches the constants for the primary profile', () {
      final paths = StoragePaths.fromDownloadsRoot(AppPaths.downloadsRoot);

      expect(paths.managerRoot, AppPaths.managerRoot);
      expect(paths.libraryRoot, AppPaths.libraryRoot);
      expect(paths.contentRoot, AppPaths.contentRoot);
      expect(paths.defaultImportRoot, AppPaths.defaultImportRoot);
      expect(paths.legacyLibraryRoots, AppPaths.legacyLibraryRoots);
      expect(paths.legacyContentRoots, AppPaths.legacyContentRoots);
    });

    test('moves the Downloads-scoped legacy roots with the profile', () {
      final paths = StoragePaths.fromDownloadsRoot('/storage/10,ABCD-1234/Download');

      // The historical /storage/emulated/0/... roots are primary-profile only
      // and stay literal; only the ones inside Downloads follow the profile.
      expect(
        paths.legacyLibraryRoots,
        <String>[
          '/storage/emulated/0/ROMs/Switch',
          '/storage/emulated/0/ROMs',
          '/storage/emulated/0/ROM',
          '/storage/10,ABCD-1234/Download/ROM',
        ],
      );
      expect(
        paths.legacyContentRoots,
        <String>[
          '/storage/emulated/0/Content',
          '/storage/10,ABCD-1234/Download/Content',
        ],
      );
    });

    test('no legacy root overlaps an active root', () {
      final paths = StoragePaths.fromDownloadsRoot('/storage/10,ABCD-1234/Download');
      final active = <String>[
        paths.downloadsRoot,
        paths.managerRoot,
        paths.libraryRoot,
        paths.contentRoot,
      ];

      for (final legacy in [
        ...paths.legacyLibraryRoots,
        ...paths.legacyContentRoots,
      ]) {
        expect(active, isNot(contains(legacy)),
            reason: 'legacy root still active: $legacy');
        expect(legacy.startsWith('/'), isTrue, reason: 'not absolute: $legacy');
      }
    });
  });

  group('AppPaths.load', () {
    tearDown(AppPaths.restoreForTesting);

    test('falls back to the primary-profile default off-device', () async {
      // No Android platform channel here: whatever the host's path_provider
      // answers (nothing, or a desktop Downloads dir), it is not Android
      // shared storage, so the documented fallback applies.
      final paths = await AppPaths.load();

      expect(paths.downloadsRoot, AppPaths.downloadsRoot);
      expect(paths.libraryRoot, AppPaths.libraryRoot);
      expect(paths.contentRoot, AppPaths.contentRoot);
      expect(paths.legacyLibraryRoots, AppPaths.legacyLibraryRoots);
      expect(paths.legacyContentRoots, AppPaths.legacyContentRoots);
    });

    test('memoizes the resolution across calls', () async {
      final first = await AppPaths.load();

      expect(identical(await AppPaths.load(), first), isTrue);
    });

    test('overrideForTesting pins the roots and restoreForTesting drops them',
        () async {
      final pinned = StoragePaths.fromDownloadsRoot('/storage/10,ABCD-1234/Download');
      AppPaths.overrideForTesting(pinned);

      expect(identical(await AppPaths.load(), pinned), isTrue);
      expect((await AppPaths.load()).libraryRoot,
          '/storage/10,ABCD-1234/Download/ROM Manager/ROMs');

      AppPaths.restoreForTesting();

      expect((await AppPaths.load()).downloadsRoot, AppPaths.downloadsRoot);
    });
  });

  group('const roots', () {
    test('the constants stay primary-profile literals', () {
      // The constants are the fallback, so they must keep describing the
      // primary profile's mount point — not be re-derived from the resolver.
      expect(AppPaths.downloadsRoot, '/storage/emulated/0/Download');
      expect(AppPaths.managerRoot, '/storage/emulated/0/Download/ROM Manager');
      expect(AppPaths.libraryRoot, '/storage/emulated/0/Download/ROM Manager/ROMs');
      expect(AppPaths.contentRoot,
          '/storage/emulated/0/Download/ROM Manager/Content');

      // This host is not Android, so the fallback root is absent — the
      // precondition behind the library screen's empty state off-device.
      expect(Directory(AppPaths.libraryRoot).existsSync(), isFalse);
    });
  });
}
