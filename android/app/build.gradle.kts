import java.io.File
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material is read from android/key.properties, which is NOT
// committed (see .gitignore) because it holds the keystore password.
//
// When the file is missing we fall back to the debug key so that
// `flutter run --release` still works on a fresh clone -- but a debug-signed
// build must NEVER be distributed: APK self-update requires the update to be
// signed with the exact same key as the installed build.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
} else {
    logger.lifecycle(
        "[signing] android/key.properties not found -> release build will use the DEBUG key. " +
            "Local testing only, not for distribution. Run tool/setup_android_keystore.ps1 to set up release signing.",
    )
}

android {
    namespace = "com.noteapp.taskmaster.v6"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.noteapp.taskmaster.v6"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                // Absolute path, as written by the setup script. Using a raw
                // File() avoids depending on the enclosing DSL's file() scope.
                //
                // java.util.Properties.load() unescapes backslashes, so a Windows
                // path must be stored doubled ('D:\\Dev\\...'). If it was written
                // verbatim, '\t' becomes a TAB and the path is silently mangled --
                // AGP would then fail with a confusing "Keystore file ... not
                // found" naming a path that looks nothing like what was typed.
                // Fail here with the real value and the fix instead.
                val storeFilePath = keystoreProperties.getProperty("storeFile")
                if (storeFilePath != null && storeFilePath.contains('\t')) {
                    throw GradleException(
                        "[signing] android/key.properties has a corrupted storeFile: " +
                            "it contains a TAB, which means the path was written with " +
                            "single backslashes. java.util.Properties.load() treats " +
                            "'\\t' as an escape. Rewrite it with doubled backslashes, " +
                            "e.g. storeFile=D:\\\\Dev\\\\keystore\\\\taskmaster-release.jks " +
                            "(or re-run tool/setup_android_keystore_auto.ps1).",
                    )
                }
                storeFile = storeFilePath?.let { File(it) }
                // Catch a missing keystore here so the message names the resolved
                // absolute path, rather than letting validateSigningRelease report
                // it against a gradle-relative path that is hard to interpret.
                val resolvedStoreFile = storeFile
                if (resolvedStoreFile != null && !resolvedStoreFile.exists()) {
                    throw GradleException(
                        "[signing] keystore not found at ${resolvedStoreFile.absolutePath}. " +
                            "Fix storeFile in android/key.properties, or run " +
                            "tool/setup_android_keystore_auto.ps1 to regenerate.",
                    )
                }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
