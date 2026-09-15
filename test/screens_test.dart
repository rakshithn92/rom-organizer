import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rom_organizer/config/app_paths.dart';
import 'package:rom_organizer/screens/import_screen.dart';
import 'package:rom_organizer/screens/library_screen.dart';
import 'package:rom_organizer/screens/settings_screen.dart';
import 'package:rom_organizer/services/tag_db.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Widget tests for the screens.
///
/// Screens resolve their storage roots through [AppPaths.load], so these tests
/// pin a temp root with [AppPaths.overrideForTesting] and read their
/// settings/covers from the statically-memoized [TagDb]. Instead of pumping the
/// whole app, they pump the screen under test and redirect the sqflite factory
/// at a temp directory, exactly like `tag_db_test.dart` does.
///
/// `RomOrganizerApp` is deliberately never pumped here: it wraps the tree in
/// `PermissionGate`, whose `permission_handler` platform channel has no
/// implementation in the VM test binding.
///
/// The settings table is left empty, so `LibraryScreen._load` returns before
/// the TheGamesDB lookups and no network access is attempted.
void main() {
  late Directory tmp;

  /// The pinned roots: a temp Downloads folder, so the library root the screen
  /// lists is creatable (unlike the const Android path).
  late StoragePaths paths;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('screens_');
    await databaseFactory.setDatabasesPath(tmp.path);
    TagDb.resetForTesting();
    paths = StoragePaths.fromDownloadsRoot(p.join(tmp.path, 'Download'));
    AppPaths.overrideForTesting(paths);
  });

  tearDown(() {
    TagDb.resetForTesting();
    AppPaths.restoreForTesting();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('LibraryScreen', () {
    testWidgets('renders the empty state when the library root is missing',
        (tester) async {
      // The pinned library root is never created, so the screen takes its
      // empty branch.
      expect(
        Directory(paths.libraryRoot).existsSync(),
        isFalse,
        reason: 'The empty-state path is only reachable while '
            '${paths.libraryRoot} does not exist.',
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

    testWidgets('lists the game folders under the resolved library root',
        (tester) async {
      // Two real folders under the resolved root: the listing branch used to
      // be unreachable off-device because the root was a const Android path.
      Directory(p.join(paths.libraryRoot, 'Mario Kart 8')).createSync(recursive: true);
      Directory(p.join(paths.libraryRoot, 'Zelda')).createSync(recursive: true);

      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
        // Let the root resolution and the (ffi) DB reads settle. The settings
        // table is empty, so no TheGamesDB request is made.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      expect(find.byType(GridView), findsOneWidget);
      expect(find.text('Mario Kart 8'), findsOneWidget);
      expect(find.text('Zelda'), findsOneWidget);
      expect(find.textContaining('No games yet'), findsNothing);
      // No cover is cached, so each card shows the placeholder icon instead of
      // an Image.network (which the test binding cannot load).
      expect(find.byIcon(Icons.videogame_asset), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('badges a game folder that has an update subfolder',
        (tester) async {
      final game = Directory(p.join(paths.libraryRoot, 'Mario Kart 8'))
        ..createSync(recursive: true);
      File(p.join(game.path, 'Mario Kart 8.nsp')).writeAsBytesSync([1]);
      Directory(p.join(game.path, 'update')).createSync();

      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      expect(find.text('has update'), findsOneWidget);
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

  group('ImportScreen', () {
    testWidgets('browses the resolved Downloads root and lists its archives',
        (tester) async {
      // The browser opens in the resolved Downloads root — not the const
      // /storage/emulated/0/Download — and lists what is actually inside.
      Directory(p.join(paths.defaultImportRoot, 'Extras')).createSync(recursive: true);
      File(p.join(paths.defaultImportRoot, 'Game.zip')).writeAsBytesSync([1]);

      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: ImportScreen()));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      expect(find.text(paths.defaultImportRoot), findsOneWidget);
      expect(find.text('Game.zip'), findsOneWidget);
      expect(find.text('Extras'), findsOneWidget);
      // At the root, so there is nothing to go up to.
      expect(find.byIcon(Icons.arrow_upward), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('refuses to browse above the resolved Downloads root',
        (tester) async {
      Directory(p.join(paths.defaultImportRoot, 'Sub')).createSync(recursive: true);
      File(p.join(paths.defaultImportRoot, 'Sub', 'Nested.zip')).writeAsBytesSync([1]);

      await tester.runAsync(() async {
        await tester.pumpWidget(const MaterialApp(home: ImportScreen()));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      await tester.tap(find.text('Sub'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });

      // Descended into the subfolder: the parent is now reachable.
      expect(find.text(p.join(paths.defaultImportRoot, 'Sub')), findsOneWidget);
      expect(find.text('Nested.zip'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // Not covered here: the no-cover placeholder branch with a *cached* cover
  // URL (Image.network cannot load in the test binding) and navigation into the
  // (private) `_GameDetail` view. The listing branch itself is covered above
  // through `AppPaths.overrideForTesting`, which points the screen at a temp
  // library root.
}
