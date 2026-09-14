import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is resolved in this priority order:
//   1. android/key.properties — local builds. Never committed (see .gitignore).
//   2. ORG_ROM_* environment variables — CI, where GitHub Secrets are injected as env vars.
//   3. the debug signing config — so `flutter run --release` still works on a machine with
//      no keystore at all. Release artifacts shipped to users MUST come from (1) or (2).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

val releaseStoreFile: String? =
    keystoreProperties.getProperty("storeFile") ?: System.getenv("ORG_ROM_KEYSTORE_PATH")
val releaseStorePassword: String? =
    keystoreProperties.getProperty("storePassword") ?: System.getenv("ORG_ROM_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? =
    keystoreProperties.getProperty("keyAlias") ?: System.getenv("ORG_ROM_KEY_ALIAS")
val releaseKeyPassword: String? =
    keystoreProperties.getProperty("keyPassword") ?: System.getenv("ORG_ROM_KEY_PASSWORD")

// Partial setup (e.g. a storeFile with no passwords) is treated as "not configured" so we
// fall back cleanly instead of failing with an obscure signing error.
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }

android {
    namespace = "com.rakshith.rom_organizer"
    // permission_handler_android requires compileSdk 37+.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.rakshith.rom_organizer"
        // Pinned to the Flutter 3.47.1 toolchain defaults (minSdk 24 / targetSdk 36) instead of
        // referencing flutter.minSdkVersion / flutter.targetSdkVersion. This app relies on
        // scoped-storage behavior (MANAGE_EXTERNAL_STORAGE + /Download direct access), so a
        // Flutter upgrade must never silently move these values out from under it.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // CI and local release builds prefer the real key (key.properties or ORG_ROM_*
            // env vars). Without one we fall back to the debug key so `flutter run --release`
            // never breaks — such an artifact simply must not be published.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 shrinking. Flutter ships its own keep rules and the plugins here are
            // platform-channel only, so no custom proguard file is needed; add one via
            // proguardFiles(...) if a future dependency needs it.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
