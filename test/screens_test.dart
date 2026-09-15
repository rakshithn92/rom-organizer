import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/config/app_paths.dart';
import 'package:rom_organizer/screens/library_screen.dart';
import 'package:rom_organizer/screens/settings_screen.dart';
import 'package:rom_organizer/services/tag_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget tests for the screens.
///
/// Screens read their storage roots straight from [AppPaths] (const Android
/// paths with no injection seam) and their settings/covers from the
/// statically-memoized [TagDb]. So instead of pumping the whole app, these
/// tests pump the screen under test and redirect the sqflite factory at a temp
/// directory, exactly like `tag_db_test.dart` does.
///
/// `RomOrganizerApp` is deliberately never pumped here: it wraps the tree in
/// `PermissionGate`, whose `permission_handler` platform channel has no
/// implementation in the VM test binding.
///
/// The settings table is left empty, so `LibraryScreen._load` returns before
/// the TheGamesDB lookups and no network access is attempted.
void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('screens_');
    await databaseFactory.setDatabasesPath(tmp.path);
    TagDb.resetForTesting();
  });

  tearDown(() {
    TagDb.resetForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('LibraryScreen', () {
    testWidgets('renders the empty state when the library root is missing',
        (tester) async {
      // This host is not Android, so the hardcoded library root is absent and
      // the screen takes its empty branch.
      expect(
        Directory(AppPaths.libraryRoot).existsSync(),
        isFalse,
        reason: 'The empty-state path is only reachable while '
            '${AppPaths.libraryRoot} does not exist.',
      );

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('No games yet'), findsOneWidget);
      expect(find.byType(GridView), findsNothing);
      // The load finished: the empty branch replaced the spinner.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tears down cleanly when disposed right after mounting',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));

      // Dispose right after mounting, then give the async tail of `_load` a
      // window to resolve against the unmounted state. Note the empty-library
      // path itself finishes synchronously (no games means no DB reads), so
      // this covers the teardown path rather than a pending cover fetch.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      expect(find.byType(LibraryScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('SettingsScreen', () {
    testWidgets('replaces the spinner with the form once the key is loaded',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

      // The key read is genuinely pending, so the first frame is the spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      // Let the real (ffi) DB read complete and rebuild.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('API key'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives dispose while its key load is still pending',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Unmount first; the pending `_load` read then resolves with no state
      // left to set, which must not surface as an error.
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();

      expect(find.byType(SettingsScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  // Not covered here: 'lists game folders from the library root', the
  // no-cover placeholder icon, and navigation into the (private) `_GameDetail`
  // view. All of them need at least one game folder under
  // `Directory(AppPaths.libraryRoot)`, a const Android path that does not
  // exist on this host and cannot be injected (`AppPaths` is const and
  // `LibraryScreen` takes no root parameter). Creating `/storage/emulated/0`
  // would mean writing outside the workspace as root, so the listing branch is
  // exercised on-device only.
}
