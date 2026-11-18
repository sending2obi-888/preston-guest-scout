plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.prestonmotor.preston_guest_scout"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    val hasPrestonKeystore = file("preston-signing.keystore").exists()

    signingConfigs {
        if (hasPrestonKeystore) {
            create("preston") {
                storeFile = file("preston-signing.keystore")
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    defaultConfig {
        applicationId = "com.prestonmotor.preston_guest_scout"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        debug {
            signingConfig = if (hasPrestonKeystore) {
                signingConfigs.getByName("preston")
            } else {
                signingConfigs.getByName("debug")
            }
        }
        release {
            signingConfig = if (hasPrestonKeystore) {
                signingConfigs.getByName("preston")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("com.google.android.gms:play-services-auth:21.2.0")
}

flutter {
    source = "../.."
}
