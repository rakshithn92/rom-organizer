import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/title_parser.dart';

void main() {
  group('TitleParser.titleId', () {
    test('extracts a title ID from a bracketed filename', () {
      expect(
        TitleParser.titleId('[0100C1B00A3A8000] Dragon Quest XI.nsp'),
        '0100C1B00A3A8000',
      );
    });

    test('extracts a title ID from a bare filename', () {
      expect(
        TitleParser.titleId('Dragon Quest XI 0100C1B00A3A8000.nsp'),
        '0100C1B00A3A8000',
      );
    });

    test('returns null when no title ID present', () {
      expect(TitleParser.titleId('The Legend of Zelda.nsp'), isNull);
      expect(TitleParser.titleId('Game Update v1.6.0.nsp'), isNull);
    });
  });
}
