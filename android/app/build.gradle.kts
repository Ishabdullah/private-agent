plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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
