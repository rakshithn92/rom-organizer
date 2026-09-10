import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/file_mover.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync('mover_test_');
  });

  tearDown(() {
    if (temporaryDirectory.existsSync()) {
      temporaryDirectory.deleteSync(recursive: true);
    }
  });

  test('moves a file without overwriting an existing destination', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    final destination = '${temporaryDirectory.path}/destination.nsp';

    expect(FileMover.moveFile(source.path, destination), isTrue);
    expect(source.existsSync(), isFalse);
    expect(File(destination).readAsBytesSync(), [1, 2, 3]);

    final second = File('${temporaryDirectory.path}/second.nsp')
      ..writeAsBytesSync([4]);
    expect(
      () => FileMover.moveFile(second.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(second.existsSync(), isTrue);
    expect(File(destination).readAsBytesSync(), [1, 2, 3]);
  });

  test('moves a directory recursively', () {
    final source = Directory('${temporaryDirectory.path}/source')..createSync();
    final nested = Directory('${source.path}/update')..createSync();
    File('${nested.path}/update.nsp').writeAsBytesSync([1]);
    final destination = '${temporaryDirectory.path}/destination';

    FileMover.moveDirectory(source.path, destination);

    expect(source.existsSync(), isFalse);
    expect(File('$destination/update/update.nsp').existsSync(), isTrue);
  });
}
