plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.romanslack.dual_cameras_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.romanslack.dual_cameras_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // StoryCam ships ARM64 only: the sherpa-onnx / plugin AARs carry
        // armeabi-v7a and x86_64 .so files that would otherwise leak into
        // the APK (run 43006787011 shipped all three ABIs, ~40 MB extra).
        // NOTE: ndk.abiFilters alone did NOT strip them — run 43008152191
        // (a49a302) still shipped all three ABIs at the same 95.7 MB.
        // AGP's packaging exclusion is what actually drops AAR jniLibs.
        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    packaging {
        jniLibs {
            excludes += "lib/armeabi-v7a/*"
            excludes += "lib/x86_64/*"
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
