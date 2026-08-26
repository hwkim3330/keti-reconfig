plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.keti.reconfig"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // Distinct from the namespace on purpose: the build deployed from the
        // Mac is signed with a different debug keystore, so reusing that id
        // would fail with INSTALL_FAILED_UPDATE_INCOMPATIBLE. This installs
        // alongside it instead of forcing an uninstall.
        applicationId = "com.keti.tsn.console"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
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

    useLibrary("android.car")
}

dependencies {
    implementation("ai.pleos.playground:Vehicle:2.0.3")
    implementation("com.fasterxml.jackson.dataformat:jackson-dataformat-cbor:2.16.0")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.16.0")
}

flutter {
    source = "../.."
}
