plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.storycam"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time APIs: its AAR
        // metadata requires core library desugaring (added in 0.5.2,
        // when the plugin arrived for the model-download notification).
        isCoreLibraryDesugaringEnabled = true
    }

    // Target ABI for this build, driven by the STORYCAM_ABI env var.
    // Default "arm64-v8a" (the Play release build). The emulator
    // workflows set STORYCAM_ABI=x86_64. See the packaging block below
    // for why this must stay in sync with the excludes.
    val targetAbi = System.getenv("STORYCAM_ABI") ?: "arm64-v8a"

    defaultConfig {
        // StoryCam's Play identity. Play forbids changing the applicationId
        // after the first release, so this was set before the first upload
        // (renamed from the plugin demo's com.romanslack.dual_cameras_example
        // in 0.5.4 — no production users existed yet, so the rename was free).
        applicationId = "app.storycam"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // StoryCam ships one ABI per build: the sherpa-onnx / plugin AARs
        // carry armeabi-v7a and x86_64 .so files that would otherwise leak
        // into the APK (run 43006787011 shipped all three ABIs, ~40 MB
        // extra). NOTE: ndk.abiFilters alone did NOT strip them — run
        // 43008152191 (a49a302) still shipped all three ABIs at the same
        // 95.7 MB. AGP's packaging exclusion is what actually drops AAR
        // jniLibs. Both follow targetAbi (see above): the unconditional
        // excludes used to strip x86_64 too, so the x86_64 emulator build
        // shipped with NO native libs and crashed on launch ("Could not
        // find 'libflutter.so'. Looked for: [x86_64, arm64-v8a], but only
        // found: []" — run 43528021798).
        ndk {
            abiFilters += targetAbi
        }
    }

    packaging {
        jniLibs {
            for (abi in listOf("armeabi-v7a", "arm64-v8a", "x86_64")) {
                if (abi != targetAbi) excludes += "lib/$abi/*"
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
