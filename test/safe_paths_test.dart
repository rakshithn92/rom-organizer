import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/safe_paths.dart';

void main() {
  group('SafePaths.gameFolder', () {
    test('joins a normal game title below the library root', () {
      expect(
        SafePaths.gameFolder('/library', 'The Legend of Zelda'),
        '/library/The Legend of Zelda',
      );
    });

    test('rejects traversal and nested path components', () {
      expect(
        () => SafePaths.gameFolder('/library', '../outside'),
        throwsFormatException,
      );
      expect(
        () => SafePaths.gameFolder('/library', 'series/game'),
        throwsFormatException,
      );
    });

    test('rejects blank and control-character titles', () {
      expect(
        () => SafePaths.gameFolder('/library', '   '),
        throwsFormatException,
      );
      expect(
        () => SafePaths.gameFolder('/library', 'game\nname'),
        throwsFormatException,
      );
    });

    test('rejects a persisted target outside the library', () {
      expect(
        () => SafePaths.existingGameFolder('/library', '/other/game'),
        throwsFormatException,
      );
    });
  });
}
