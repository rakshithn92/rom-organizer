import 'package:flutter_test/flutter_test.dart';
import 'package:rom_organizer/main.dart';

void main() {
  testWidgets('app builds and shows the browser', (tester) async {
    await tester.pumpWidget(const RomOrganizerApp());
    expect(find.byType(RomOrganizerApp), findsOneWidget);
  });
}
