import 'dart:io';

import 'package:flutter/services.dart';

/// Launches a Switch ROM in whatever app the user picks.
///
/// The intent is fired from the Android side (MainActivity.kt), which builds a
/// FileProvider content:// URI — Android 7+ blocks raw file:// URIs between
/// apps. Android then shows the system "open with" chooser listing every app
/// that can open the file (emulators, etc.).
class EmulatorLauncher {
  static const _channel = MethodChannel('rom_organizer/emulator');

  /// Fires the intent to open [romPath]. Returns true if the intent was sent;
  /// false if the file doesn't exist or the intent failed.
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
