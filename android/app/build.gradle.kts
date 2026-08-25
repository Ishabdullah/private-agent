import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config (Phase 14). key.properties is gitignored and points
// at a keystore stored outside the repo entirely (see android/.gitignore and
// docs/ANDROID_DIGITAL_ASSISTANT_PROGRESS.md's Phase 14 entry for where).
// Falls back to null (debug signing) if key.properties isn't present, so a
// fresh checkout without the keystore still builds debug/profile variants.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.orailnoor.privateagent"
    // flutter.compileSdkVersion currently resolves to 36, but flutter_secure_storage
    // requires compiling against 37 (backward compatible) — pinned explicitly per
    // Flutter's own build-time recommendation rather than left to the default.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.orailnoor.privateagent"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when key.properties is present (see above);
            // falls back to the debug keystore otherwise so `flutter run
            // --release` still works on a fresh checkout without one.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // sherpa-onnx (Phase 5 wake-word KWS engine) — official JitPack coordinate
    // per k2-fsa/sherpa-onnx's own jitpack.yml (groupId com.github.k2-fsa,
    // artifactId sherpa-onnx, version pinned to a GitHub release tag). This
    // AAR bundles the Android .so per ABI; resolution is being verified here
    // before any Kotlin code depends on it (see plan doc Section 8.3.2).
    implementation("com.github.k2-fsa:sherpa-onnx:1.13.5") {
        // The published pom pulls in the desktop-JVM jar (same package,
        // duplicate classes) as a transitive dependency — Android only
        // needs the AAR, which already bundles the native .so per ABI.
        exclude(group = "com.github.k2-fsa.sherpa-onnx", module = "sherpa-onnx-jvm")
    }
}
