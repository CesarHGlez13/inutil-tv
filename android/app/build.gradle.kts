plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.cesar.tubotv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.cesar.tubotv"
        // media_kit requiere API 21+; Flutter 3.50 fija el piso efectivo en API 24 (Android 7.0).
        minSdk = maxOf(21, flutter.minSdkVersion)
        // Fijado en API 35 (Android 15 estable): compileSdk 36 compila plugins recientes
        // sin disparar rechazos de PackageInstaller OEM en Android 11-15.
        targetSdk = 35
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // Clave propia de Inútil TV (guardar copia de seguridad del .keystore)
            storeFile = file("tubotv-release.keystore")
            storePassword = "tubotv2026"
            keyAlias = "tubotv"
            keyPassword = "tubotv2026"
            // Firmar con v1 + v2 + v3 simultáneamente para máxima compatibilidad
            // con Android 7-16, Android TV Boxes y gestores/instaladores OEM.
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
        }
    }

    packaging {
        jniLibs {
            // Extraer .so al instalar evita fallos de alineación 16 KB en dispositivos
            // Android 15/16 con páginas de 16 KB y reduce el tamaño del APK.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
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
