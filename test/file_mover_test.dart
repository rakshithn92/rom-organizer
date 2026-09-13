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

  test('a failed move leaves the source intact and no destination file', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    // A regular file in the destination's parent slot makes both renameSync and
    // the copy fallback fail, without a partial copy to clean up (failure
    // injection mid-copy is not deterministically reproducible here).
    final blocker = File('${temporaryDirectory.path}/blocker.nsp')
      ..writeAsBytesSync([9]);
    final destination = '${blocker.path}/child.nsp';

    expect(
      () => FileMover.moveFile(source.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(source.readAsBytesSync(), [1, 2, 3]);
    expect(File(destination).existsSync(), isFalse);
    expect(blocker.readAsBytesSync(), [9]);
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
