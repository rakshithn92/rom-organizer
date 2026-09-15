import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rom_organizer/services/rom_scanner.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rom_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File write(String name, {int size = 100}) {
    final f = File('${tmp.path}/$name');
    f.writeAsBytesSync(List.filled(size, 0));
    return f;
  }

  test('recognizes Switch ROM extensions', () {
    write('game.nsp');
    write('game2.xci');
    write('game3.nsz');
    write('game4.xcz');
    write('game5.nca');
    write('notes.txt'); // not a ROM
    write('image.png'); // not a ROM

    final roms = RomScanner().scan(tmp);
    expect(roms.length, 5);
    expect(roms.map((r) => r.extension).toSet(),
        {'.nsp', '.xci', '.nsz', '.xcz', '.nca'});
  });

  test('non-recursive scan ignores subdirectories', () {
    write('top.nsp');
    Directory('${tmp.path}/sub').createSync();
    write('sub/nested.xci');

    final roms = RomScanner().scan(tmp);
    expect(roms.length, 1);
    expect(roms.single.baseName, 'top');
  });

  test('recursive scan descends into subdirectories', () {
    write('top.nsp');
    Directory('${tmp.path}/sub').createSync();
    write('sub/nested.xci');

    final roms = RomScanner().scan(tmp, recursive: true);
    expect(roms.length, 2);
  });

  test('baseName strips the extension, sizeLabel formats GB', () {
    write('Zelda.nsp');
    final roms = RomScanner().scan(tmp);
    final r = roms.single;
    expect(r.baseName, 'Zelda');
    final big = RomFile(
      path: r.path,
      name: r.name,
      baseName: r.baseName,
      extension: r.extension,
      sizeBytes: 3 * 1024 * 1024 * 1024, // 3 GB, no giant file needed
      modified: r.modified,
    );
    expect(big.sizeLabel, '3.0 GB');
  });

  test('scan of a missing directory returns empty', () {
    expect(RomScanner().scan(Directory('${tmp.path}/nope')), isEmpty);
  });

  test('findImportables finds loose ROMs and archives recursively', () {
    write('top.nsp');
    write('game.zip');
    Directory('${tmp.path}/sub').createSync();
    write('sub/nested.xci');
    write('sub/notes.txt'); // not importable

    final found = RomScanner().findImportables(tmp);
    expect(found.length, 3);
    expect(found.any((f) => f.endsWith('top.nsp')), isTrue);
    expect(found.any((f) => f.endsWith('game.zip')), isTrue);
    expect(found.any((f) => f.endsWith('nested.xci')), isTrue);
  });

  test('findImportables skips excluded library roots', () {
    write('download.nsp');
    final library = Directory('${tmp.path}/Switch')..createSync();
    File('${library.path}/organized.nsp').writeAsBytesSync([1]);

    final found = RomScanner().findImportables(
      tmp,
      excludedRoots: {library.path},
    );

    expect(found.any((f) => f.endsWith('download.nsp')), isTrue);
    expect(found.any((f) => f.endsWith('organized.nsp')), isFalse);
  });

  test('finds an existing base folder from an update title ID', () {
    final library = Directory('${tmp.path}/Switch')..createSync();
    final game = Directory('${library.path}/My Game')..createSync();
    File('${game.path}/My Game [0100C1B00A3A8000].nsp')
        .writeAsBytesSync([1]);

    final found = RomScanner().findGameFolderByTitleId(
      library,
      '0100C1B00A3A8800',
    );

    expect(p.equals(found!, game.path), isTrue);
  });

  test('does not treat an update misplaced at the root as a base game', () {
    final library = Directory('${tmp.path}/Switch')..createSync();
    final orphan = Directory('${library.path}/Orphan Update')..createSync();
    File('${orphan.path}/Update [0100C1B00A3A8800][v65536].nsp')
        .writeAsBytesSync([1]);

    final found = RomScanner().findGameFolderByTitleId(
      library,
      '0100C1B00A3A8800',
    );

    expect(found, isNull);
  });

  test('survives a symlink cycle inside the scanned tree', () {
    write('top.nsp');
    final sub = Directory('${tmp.path}/a')..createSync();
    File('${sub.path}/inner.xci').writeAsBytesSync([1]);
    // A self-referencing symlink recurses forever if the walker follows links;
    // `followLinks: false` leaves it as a plain (skipped) Link entry.
    Link('${sub.path}/loop').createSync(sub.path);

    final found = RomScanner().findImportables(tmp);
    expect(found, hasLength(2));
    expect(found.map(p.basename).toSet(), {'top.nsp', 'inner.xci'});
    expect(RomScanner().scan(tmp, recursive: true), hasLength(2));
  });

  test('does not follow a symlink to a ROM outside the scanned tree', () {
    final outside = Directory('${tmp.path}/outside')..createSync();
    final realRom = File('${outside.path}/real.nsp')..writeAsBytesSync([1]);
    final scanned = Directory('${tmp.path}/scanned')..createSync();
    File('${scanned.path}/own.nsp').writeAsBytesSync([2]);
    Link('${scanned.path}/link.nsp').createSync(realRom.path);

    expect(RomScanner().findImportables(scanned).map(p.basename).toList(),
        ['own.nsp']);
    expect(RomScanner().scan(scanned).map((r) => r.name).toList(), ['own.nsp']);
  });

  test('does not descend into a symlinked directory', () {
    final outside = Directory('${tmp.path}/outside')..createSync();
    File('${outside.path}/hidden.nsp').writeAsBytesSync([1]);
    final scanned = Directory('${tmp.path}/scanned')..createSync();
    File('${scanned.path}/own.nsp').writeAsBytesSync([2]);
    Link('${scanned.path}/linkdir').createSync(outside.path);

    expect(RomScanner().findImportables(scanned).map(p.basename).toList(),
        ['own.nsp']);
    expect(RomScanner().scan(scanned, recursive: true), hasLength(1));
  });

  test(
    'skips an unreadable subdirectory instead of throwing',
    () {
      write('top.nsp');
      final sub = Directory('${tmp.path}/sub')..createSync();
      File('${sub.path}/nested.xci').writeAsBytesSync([1]);
      final blocked = Directory('${tmp.path}/blocked')..createSync();
      File('${blocked.path}/hidden.nsp').writeAsBytesSync([2]);

      Process.runSync('chmod', ['000', blocked.path]);
      var unreadable = false;
      try {
        blocked.listSync();
      } on FileSystemException {
        unreadable = true;
      }
      if (!unreadable) {
        // A root runner (or a filesystem ignoring mode bits) can still read the
        // tree, so the injection cannot be produced honestly; assert the plain
        // walk instead of pinning a failure that cannot happen.
        expect(RomScanner().scan(tmp, recursive: true), hasLength(3));
        expect(RomScanner().findImportables(tmp), hasLength(3));
        return;
      }
      try {
        final roms = RomScanner().scan(tmp, recursive: true);
        expect(roms.map((r) => r.name).toSet(), {'top.nsp', 'nested.xci'});
        final found = RomScanner().findImportables(tmp);
        expect(found.map(p.basename).toSet(), {'top.nsp', 'nested.xci'});
      } finally {
        Process.runSync('chmod', ['755', blocked.path]);
      }
    },
    skip: _runningAsRoot
        ? 'chmod 000 is bypassed when the suite runs as root'
        : null,
  );
}

/// True when the suite runs as uid 0, where `chmod 000` does not block reads.
final bool _runningAsRoot = () {
  try {
    return Process.runSync('id', ['-u']).stdout.toString().trim() == '0';
  } catch (_) {
    return false;
  }
}();
