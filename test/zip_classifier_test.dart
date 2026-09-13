import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/services/zip_classifier.dart';

void main() {
  group('ZipClassifier version markers (M7)', () {
    test('a base ROM with a version suffix is NOT an update', () {
      expect(ZipClassifier.classifyPath('Game v1.0.nsp'), RomEntryKind.base);
      expect(ZipClassifier.classifyPath('Game.v2.3.1.nsp'), RomEntryKind.base);
    });

    test('an update carrying any version number is not decided by the number',
        () {
      // No "update" word and no update Title ID: the version alone cannot
      // prove this is an update, so it stays base.
      expect(ZipClassifier.classifyPath('Game v6.0.nsp'), RomEntryKind.base);
    });

    test('word markers still classify as update', () {
      expect(ZipClassifier.classifyPath('Game Update v1.6.0.nsp'),
          RomEntryKind.update);
      expect(ZipClassifier.classifyPath('Game upd.nsp'), RomEntryKind.update);
      expect(ZipClassifier.classifyPath('Game patch.nsp'), RomEntryKind.update);
    });

    test('update Title ID still classifies as update', () {
      expect(
        ZipClassifier.classifyPath('Game [0100C1B00A3A8800][v6.0].nsp'),
        RomEntryKind.update,
      );
    });

    test('DLC markers are unchanged', () {
      expect(ZipClassifier.classifyPath('Game DLC.nsp'), RomEntryKind.dlc);
      expect(ZipClassifier.classifyPath('Game add-on.nsp'), RomEntryKind.dlc);
    });
  });
}
