import 'dart:io';

import 'package:rom_organizer/services/thegamesdb_client.dart';

/// Manual verification against the live TheGamesDB API.
/// Run: TGDB_KEY=key dart run tool/verify_tgdb.dart
Future<void> main() async {
  final key = Platform.environment['TGDB_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('Set TGDB_KEY env var first.');
    exit(1);
  }
  final client = TheGamesDbClient(key);
  for (final q in ['Super Mario Odyssey', 'Zelda Breath of the Wild']) {
    final m = await client.search(q);
    // ignore: avoid_print
    print('query="$q" -> title="${m?.title}" boxart="${m?.boxartUrl}"');
  }
  client.close();
}
