package com.rakshith.rom_organizer

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channel = "rom_organizer/emulator"

    // Known Switch emulator package names (label shown in the in-app chooser).
    private val emulators = mapOf(
        "org.yuzu.yuzu_emu" to "Yuzu",
        "org.yuzu.yuzu_emu.ea" to "Yuzu (EA)",
        "org.sudachi.sudachi_emu" to "Sudachi",
        "org.citron.citron_emu" to "Citron",
        "org.ryujinx.ryujinx" to "Ryujinx",
        "emu.skyline.online" to "Skyline",
        "org.strato.skyline" to "Strato",
        "com.kaihei.egg" to "Egg NS",
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchInEmulator" -> {
                        val path = call.argument<String>("path")
                        val pkg = call.argument<String>("package")
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        val ok = launchInEmulator(path, pkg)
                        result.success(ok)
                    }
                    "listEmulators" -> {
                        result.success(listEmulators())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Returns a list of installed emulator packages: [{"package": "...", "label": "..."}]
    private fun listEmulators(): List<Map<String, String>> {
        val pm: PackageManager = packageManager
        val installed = mutableListOf<Map<String, String>>()
        for ((pkg, label) in emulators) {
            try {
                pm.getPackageInfo(pkg, 0)
                installed.add(mapOf("package" to pkg, "label" to label))
            } catch (_: PackageManager.NameNotFoundException) {
                // Not installed — skip.
            }
        }
        return installed
    }

    private fun launchInEmulator(path: String, packageName: String?): Boolean {
        val file = File(path)
        if (!file.exists()) return false
        return try {
            // Build a FileProvider content:// URI (Android 7+ blocks file://).
            val uri: Uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "*/*")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                if (packageName != null) {
                    setPackage(packageName)
                }
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
