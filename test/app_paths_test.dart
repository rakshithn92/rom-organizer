import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/config/app_paths.dart';

/// Structural invariants of the constant roots.
///
/// These constants are the **primary-profile fallback** used when
/// `path_provider` cannot answer; the runtime resolution and the derived
/// profile-aware roots are covered by `app_paths_resolver_test.dart`.
void main() {
  group('AppPaths structural invariants', () {
    const activeRoots = <String>[
      AppPaths.downloadsRoot,
      AppPaths.managerRoot,
      AppPaths.libraryRoot,
      AppPaths.contentRoot,
    ];

    test('legacy roots are absolute paths', () {
      for (final root in [
        ...AppPaths.legacyLibraryRoots,
        ...AppPaths.legacyContentRoots,
      ]) {
        expect(root.startsWith('/'), isTrue, reason: 'not absolute: $root');
      }
    });

    test('legacy roots do not overlap the active roots', () {
      for (final legacy in [
        ...AppPaths.legacyLibraryRoots,
        ...AppPaths.legacyContentRoots,
      ]) {
        expect(
          activeRoots,
          isNot(contains(legacy)),
          reason: 'legacy root still active: $legacy',
        );
      }
    });
  });
}
