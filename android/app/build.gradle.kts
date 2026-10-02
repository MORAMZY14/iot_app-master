import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI environment variables override the developer's ignored key.properties.
// Missing credentials are checked only when a release build is requested, so
// normal debug builds and IDE project sync remain available without a key.
val uploadKeyProperties = Properties().apply {
    val propertiesFile = rootProject.file("key.properties")
    if (propertiesFile.isFile) {
        propertiesFile.inputStream().use { load(it) }
    }
}
fun uploadKeyValue(environmentName: String, propertyName: String): String? =
    System.getenv(environmentName)?.takeIf { it.isNotBlank() }
        ?: uploadKeyProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }

val uploadStorePath = uploadKeyValue("SMARTHOME_UPLOAD_STORE_FILE", "storeFile")
val uploadStorePassword = uploadKeyValue("SMARTHOME_UPLOAD_STORE_PASSWORD", "storePassword")
val uploadKeyAlias = uploadKeyValue("SMARTHOME_UPLOAD_KEY_ALIAS", "keyAlias")
val uploadKeyPassword = uploadKeyValue("SMARTHOME_UPLOAD_KEY_PASSWORD", "keyPassword")

val validateReleaseSigning = tasks.register("validateReleaseSigning") {
    group = "verification"
    description = "Require a private upload key for every Android release build."
    doLast {
        val missing = listOf(
            "storeFile" to uploadStorePath,
            "storePassword" to uploadStorePassword,
            "keyAlias" to uploadKeyAlias,
            "keyPassword" to uploadKeyPassword,
        ).filter { it.second.isNullOrBlank() }.map { it.first }
        if (missing.isNotEmpty()) {
            throw GradleException(
                "Android release signing is not configured. Missing: ${missing.joinToString()}. " +
                    "Set android/key.properties or SMARTHOME_UPLOAD_* environment variables. " +
                    "See docs/RELEASE.md. Debug signing is never used for release builds."
            )
        }
        val uploadStore = rootProject.file(requireNotNull(uploadStorePath))
        if (!uploadStore.isFile) {
            throw GradleException("The configured Android upload keystore does not exist.")
        }
        if (uploadKeyAlias == "androiddebugkey" || uploadStore.name == "debug.keystore") {
            throw GradleException("A debug keystore cannot be used for an Android release.")
        }
        val signingCertificate = try {
            val keystore = KeyStore.getInstance(
                uploadStore, requireNotNull(uploadStorePassword).toCharArray()
            )
            val entry = keystore.getEntry(
                requireNotNull(uploadKeyAlias),
                KeyStore.PasswordProtection(requireNotNull(uploadKeyPassword).toCharArray()),
            ) as? KeyStore.PrivateKeyEntry
            entry?.certificate as? X509Certificate
        } catch (_: Exception) {
            // Do not log signing passwords or provider-specific exception data.
            throw GradleException("Android upload key could not be loaded. Check its alias and passwords.")
        } ?: throw GradleException("Android release signing requires a private key and X.509 certificate.")
        if (signingCertificate.subjectX500Principal.name.contains("CN=Android Debug", ignoreCase = true)) {
            throw GradleException("An Android debug certificate cannot sign a release, even if renamed.")
        }
    }
}

android {
    namespace = "com.example.iot_app"
    // Keep resource linking deterministic in CI. Android 12 splash resources
    // require API 31+, and the current native dependencies are built for 35.
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Keep the ID aligned with Firebase. Changing it requires replacing the
        // Firebase platform configuration and any existing store registration.
        applicationId = "com.example.iot_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // MediaPipe GenAI local inference requires Android API 24 or newer.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = uploadStorePath?.let { rootProject.file(it) }
            storePassword = uploadStorePassword
            keyAlias = uploadKeyAlias
            keyPassword = uploadKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

tasks.matching { it.name == "preReleaseBuild" }.configureEach {
    dependsOn(validateReleaseSigning)
}

flutter {
    source = "../.."
}
