import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/config/app_paths.dart';

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
