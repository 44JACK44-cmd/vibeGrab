import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma de release.
//
// Orden de busqueda, pensado para NO depender de ningun equipo concreto:
//   1. Variables de entorno VIBEGRAB_* -> las usa GitHub Actions (secretos del repo).
//   2. Archivo android/key.properties   -> uso local (NUNCA se versiona).
//
// Si no encuentra ninguna de las dos, firma con la clave debug (solo desarrollo).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun signingValue(envName: String, propName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(propName)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingValue("VIBEGRAB_STORE_FILE", "storeFile")
val releaseStorePassword = signingValue("VIBEGRAB_STORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingValue("VIBEGRAB_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingValue("VIBEGRAB_KEY_PASSWORD", "keyPassword")

val hasReleaseSigning = releaseStoreFile != null &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    file(releaseStoreFile).exists()

// AdMob application ID for the Android manifest.
//
// The official Google test app ID is the safe default, so debug builds never
// need a secret. A production release must pass the real app ID explicitly:
//   flutter build apk --release -PadmobAppId=ca-app-pub-...~...
// or set ADMOB_APP_ID in the build environment. Dart-side ad units are also
// required; see AdConfig and RELEASE.md.
val admobAppId = (project.findProperty("admobAppId") as String?)
    ?.takeIf { it.isNotBlank() }
    ?: System.getenv("ADMOB_APP_ID")?.takeIf { it.isNotBlank() }
    ?: "ca-app-pub-3940256099942544~3347511713"

android {
    namespace = "com.example.vibegrab"
    // google_mobile_ads 9.1.0 requires compileSdk 36.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.vibegrab"
        // google_mobile_ads 9.1.0 requires API 24.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
        manifestPlaceholders["admobAppId"] = admobAppId
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword!!
                // Maxima compatibilidad entre dispositivos: v1 (JAR) + v2 + v3.
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // R8 (minificacion + ofuscacion) ya venia activo por el plugin de
            // Flutter; se declara de forma explicita para dejarlo constancia.
            isMinifyEnabled = true
            // Reglas propias del proyecto: R8 tiene que conservar lo que se
            // resuelve por reflexion en tiempo de ejecucion (Room busca su
            // <BaseDeDatos>_Impl por nombre y WorkManager la instancia asi).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Si hay clave de release configurada se usa; si no, se cae a la clave
            // debug para no romper a quien clone el repo (solo desarrollo).
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)
    implementation(libs.androidx.documentfile)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
