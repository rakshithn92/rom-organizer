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

  test('normalizes an update title ID to its base game title ID', () {
    expect(
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8800'),
      '0100C1B00A3A8000',
    );
  });

  test('keeps a base title ID unchanged and normalizes case', () {
    expect(
      TitleParser.canonicalBaseTitleId('0100c1b00a3a8000'),
      '0100C1B00A3A8000',
    );
  });

  test('does not extract a title ID from a longer hexadecimal token', () {
    expect(TitleParser.titleId('Game 0100C1B00A3A8000AB.nsp'), isNull);
  });

  test('distinguishes update and base title IDs', () {
    expect(TitleParser.isUpdateTitleId('0100C1B00A3A8800'), isTrue);
    expect(TitleParser.isUpdateTitleId('0100C1B00A3A8000'), isFalse);
    expect(TitleParser.isUpdateTitleId('not-a-title-id-800'), isFalse);
  });

  test('canonicalizes DLC add-on IDs to the base game (M9)', () {
    // Base stays base.
    expect(
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8000'),
      '0100C1B00A3A8000',
    );
    // Update folds to base.
    expect(
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8800'),
      '0100C1B00A3A8000',
    );
    // DLC add-on index folds to base.
    expect(
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8001'),
      '0100C1B00A3A8000',
    );
  });

  test('DLC add-on ID is not an update but canonicalizes to base', () {
    expect(TitleParser.isUpdateTitleId('0100C1B00A3A8001'), isFalse);
    expect(
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8001'),
      TitleParser.canonicalBaseTitleId('0100C1B00A3A8000'),
    );
  });

  test('leaves a non-title-id token unchanged', () {
    expect(TitleParser.canonicalBaseTitleId('not-a-title-id-800'),
        'NOT-A-TITLE-ID-800');
    expect(TitleParser.canonicalBaseTitleId('0100C1B00A3A8000AB'),
        '0100C1B00A3A8000AB');
  });
}
