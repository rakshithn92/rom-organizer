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

  test('a held claim rejects a second move', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    final destination = '${temporaryDirectory.path}/destination.nsp';
    // Simulate a concurrent move that already published its claim.
    final claim = Directory('$destination.claim')..createSync();
    File('${claim.path}/held').writeAsBytesSync(const [1]);

    expect(
      () => FileMover.moveFile(source.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(source.readAsBytesSync(), [1, 2, 3]);
    expect(File(destination).existsSync(), isFalse);

    claim.deleteSync(recursive: true);
  });

  test('a stale empty claim directory does not block a new move', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    final destination = '${temporaryDirectory.path}/destination.nsp';
    // A crashed run leaves an empty claim behind; it is self-healing.
    Directory('$destination.claim').createSync();

    expect(FileMover.moveFile(source.path, destination), isTrue);
    expect(source.existsSync(), isFalse);
    expect(File(destination).readAsBytesSync(), [1, 2, 3]);
    expect(Directory('$destination.claim').existsSync(), isFalse);
  });

  test('a successful move releases the claim', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    final destination = '${temporaryDirectory.path}/destination.nsp';

    expect(FileMover.moveFile(source.path, destination), isTrue);
    expect(Directory('$destination.claim').existsSync(), isFalse);
  });

  test(
      'moveFile onto a path occupied by a directory fails and leaves no '
      'partial destination', () {
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([1, 2, 3]);
    // A directory in the destination slot defeats both the rename and the copy
    // fallback, and the failed fallback must not leave a partial file behind
    // (a retry would then refuse with "already exists").
    final occupied = Directory('${temporaryDirectory.path}/occupied.nsp')
      ..createSync();

    expect(
      () => FileMover.moveFile(source.path, occupied.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(source.readAsBytesSync(), [1, 2, 3]);
    expect(File(occupied.path).existsSync(), isFalse);
    expect(occupied.existsSync(), isTrue);
    expect(occupied.listSync(), isEmpty);
    expect(Directory('${occupied.path}.claim').existsSync(), isFalse);
  });

  test('a failed move through a file-blocker parent leaves the source intact',
      () {
    // Variant of the blocker test that also pins the source bytes and the fact
    // that the claim left for the destination is released again.
    final source = File('${temporaryDirectory.path}/source.nsp')
      ..writeAsBytesSync([7, 8, 9]);
    final blocker = File('${temporaryDirectory.path}/blocker.nsp')
      ..writeAsBytesSync([1]);
    final destination = '${blocker.path}/child.nsp';

    expect(
      () => FileMover.moveFile(source.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.readAsBytesSync(), [7, 8, 9]);
    expect(File(destination).existsSync(), isFalse);
    expect(Directory('$destination.claim').existsSync(), isFalse);
  });

  test('moveDirectory leaves the source intact when the destination exists',
      () {
    final source = Directory('${temporaryDirectory.path}/source')
      ..createSync();
    File('${source.path}/game.nsp').writeAsBytesSync([1, 2, 3]);
    final existing = Directory('${temporaryDirectory.path}/destination')
      ..createSync();
    File('${existing.path}/other.nsp').writeAsBytesSync([4]);

    expect(
      () => FileMover.moveDirectory(source.path, existing.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(File('${source.path}/game.nsp').readAsBytesSync(), [1, 2, 3]);
    expect(File('${existing.path}/other.nsp').readAsBytesSync(), [4]);
    expect(File('${existing.path}/game.nsp').existsSync(), isFalse);
  });

  test(
      'moveDirectory removes its partial copy when the fallback fails on a '
      'file-blocked destination', () {
    final source = Directory('${temporaryDirectory.path}/source')
      ..createSync();
    File('${source.path}/game.nsp').writeAsBytesSync([1, 2, 3]);
    // A regular FILE in the destination slot makes `renameSync` fail (type
    // mismatch) and the copy fallback fail (cannot create the directory), so
    // the partial destination produced by this operation must be cleaned up.
    final blocker = File('${temporaryDirectory.path}/destination')
      ..writeAsBytesSync([9]);

    expect(
      () => FileMover.moveDirectory(source.path, blocker.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(source.existsSync(), isTrue);
    expect(File('${source.path}/game.nsp').readAsBytesSync(), [1, 2, 3]);
    expect(blocker.readAsBytesSync(), [9]);
    expect(Directory(blocker.path).existsSync(), isFalse);
  });
}
