import 'dart:io';

import 'package:flutter/services.dart';

/// An installed Switch emulator detected on the device.
class Emulator {
  final String package;
  final String label;
  const Emulator({required this.package, required this.label});
}

/// Launches a Switch ROM in an installed emulator.
///
/// The actual intent is fired from the Android side (MainActivity.kt), which
/// builds a FileProvider content:// URI — Android 7+ blocks raw file:// URIs
/// between apps.
class EmulatorLauncher {
  static const _channel = MethodChannel('rom_organizer/emulator');

  /// Lists the installed Switch emulators (package + label).
  static Future<List<Emulator>> listEmulators() async {
    try {
      final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
          'listEmulators');
      if (list == null) return [];
      return [
        for (final m in list)
          Emulator(
            package: m['package'] as String,
            label: m['label'] as String,
          ),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Fires the intent to open [romPath] in [emulator]. Returns true if the
  /// intent was sent; false if the file doesn't exist or the intent failed.
  static Future<bool> launch(String romPath, {Emulator? emulator}) async {
    final file = File(romPath);
    if (!file.existsSync()) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('launchInEmulator', {
        'path': romPath,
        'package': emulator?.package,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
