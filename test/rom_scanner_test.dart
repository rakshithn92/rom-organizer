import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    write('Zelda.nsp', size: 3 * 1024 * 1024 * 1024); // 3 GB
    final roms = RomScanner().scan(tmp);
    final r = roms.single;
    expect(r.baseName, 'Zelda');
    expect(r.sizeLabel, '3.0 GB');
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
}
