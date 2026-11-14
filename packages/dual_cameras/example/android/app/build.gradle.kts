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

    // Release signing (issue #32): the release build signs with the upload
    // keystore when all four STORYCAM_* env vars are set and the keystore
    // file exists; otherwise it falls back to the debug key, exactly as
    // before, so `flutter run --release`, tag builds and CI keep working.
    // Only missing variable NAMES are named in the warning — never a value.
    // CI decodes the real keystore from the STORYCAM_KEYSTORE_BASE64 secret
    // (see build-apk.yml); locally the developer places the file on disk.
    val keystoreFile = System.getenv("STORYCAM_KEYSTORE_FILE")
    val keystorePassword = System.getenv("STORYCAM_KEYSTORE_PASSWORD")
    val keyAlias = System.getenv("STORYCAM_KEY_ALIAS")
    val keyPassword = System.getenv("STORYCAM_KEY_PASSWORD")
    val missingKeystoreVars = listOf(
        "STORYCAM_KEYSTORE_FILE" to keystoreFile,
        "STORYCAM_KEYSTORE_PASSWORD" to keystorePassword,
        "STORYCAM_KEY_ALIAS" to keyAlias,
        "STORYCAM_KEY_PASSWORD" to keyPassword
    ).filter { it.second.isNullOrEmpty() }.map { it.first }
    // Guarded by hasReleaseKeystore below, so the !! uses are safe.
    val hasReleaseKeystore = missingKeystoreVars.isEmpty() &&
        keystoreFile != null && file(keystoreFile).exists()
    if (missingKeystoreVars.isNotEmpty()) {
        logger.warn(
            "StoryCam release signing: falling back to the debug key; " +
                "missing: ${missingKeystoreVars.joinToString(", ")}"
        )
    } else if (!hasReleaseKeystore) {
        logger.warn(
            "StoryCam release signing: falling back to the debug key; " +
                "keystore file not found (STORYCAM_KEYSTORE_FILE)"
        )
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreFile!!)
                storePassword = keystorePassword
                keyAlias = keyAlias
                keyPassword = keyPassword
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
