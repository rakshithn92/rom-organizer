import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/version_parser.dart';

void main() {
  group('VersionParser', () {
    test('parses vX.Y.Z from a filename', () {
      expect(VersionParser.parse('Game.Update.v1.6.0.nsp')?.toString(), '1.6.0');
      expect(VersionParser.parse('Game.v1.2.3.nsp')?.toString(), '1.2.3');
    });

    test('parses bracketed [vN] title-id style', () {
      expect(VersionParser.parse('Game[0100...][v0].nsp')?.toString(), '0.0.0');
      expect(VersionParser.parse('Game[0100...][v5].nsp')?.toString(), '5.0.0');
    });

    test('parses underscore-separated versions', () {
      expect(VersionParser.parse('Game_v1.6.0.nsp')?.toString(), '1.6.0');
    });

    test('returns null when no version present', () {
      expect(VersionParser.parse('Game.nsp'), isNull);
      expect(VersionParser.parse('The Legend of Zelda.nsp'), isNull);
    });

    test('compares versions correctly', () {
      expect(Version.fromString('1.6.0').compareTo(Version.fromString('1.7.0')),
          lessThan(0));
      expect(Version.fromString('2.0.0').compareTo(Version.fromString('1.9.9')),
          greaterThan(0));
      expect(Version.fromString('1.2.3').compareTo(Version.fromString('1.2.3')),
          0);
    });
  });
}
