import 'dart:io';

import 'package:flutter/services.dart';

/// Launches a Switch ROM in an installed emulator.
///
/// The actual intent is fired from the Android side (MainActivity.kt), which
/// builds a FileProvider content:// URI — Android 7+ blocks raw file:// URIs
/// between apps. Android then shows an "open with" chooser listing the
/// installed emulators.
class EmulatorLauncher {
  static const _channel = MethodChannel('rom_organizer/emulator');

  /// Fires the intent to open [romPath] in an emulator. Returns true if the
  /// intent was sent; false if the file doesn't exist or the intent failed.
  static Future<bool> launch(String romPath) async {
    final file = File(romPath);
    if (!file.existsSync()) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('launchInEmulator', {
        'path': romPath,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
