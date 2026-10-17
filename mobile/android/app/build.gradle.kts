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

android {
    namespace = "com.example.vibegrab"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.vibegrab"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
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
