import java.io.File

plugins {
    id("com.android.application")
}

val keystoreFile = File(
    System.getenv("ANDROID_KEYSTORE_PATH")
        ?: "${System.getProperty("user.home")}/.private_keys/freemidiplayer-upload.jks"
)
val keystorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: "freemidiplayer2026"
val keyAliasName = System.getenv("ANDROID_KEY_ALIAS") ?: "upload"
val keyPasswordValue = System.getenv("ANDROID_KEY_PASSWORD") ?: "freemidiplayer2026"

val admobAppId = System.getenv("ADMOB_ANDROID_APP_ID")
    ?: "ca-app-pub-3940256099942544~3347511713"
val admobBannerUnitId = System.getenv("ADMOB_ANDROID_BANNER_UNIT_ID")
    ?: "ca-app-pub-3940256099942544/6300978111"
val admobInterstitialUnitId = System.getenv("ADMOB_ANDROID_INTERSTITIAL_UNIT_ID")
    ?: "ca-app-pub-3940256099942544/1033173712"

android {
    namespace = "com.lukeknoble.freemidiplayer"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.lukeknoble.freemidiplayer"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        manifestPlaceholders["admobAppId"] = admobAppId
        buildConfigField("String", "ADMOB_APP_ID", "\"$admobAppId\"")
        buildConfigField("String", "ADMOB_BANNER_UNIT_ID", "\"$admobBannerUnitId\"")
        buildConfigField("String", "ADMOB_INTERSTITIAL_UNIT_ID", "\"$admobInterstitialUnitId\"")
        buildConfigField("String", "APP_DISPLAY_NAME", "\"free MIDI player (FOSS)\"")
    }

    signingConfigs {
        create("release") {
            if (keystoreFile.exists()) {
                storeFile = keystoreFile
                storePassword = keystorePassword
                keyAlias = keyAliasName
                keyPassword = keyPasswordValue
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            if (keystoreFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("com.google.android.gms:play-services-ads:23.6.0")

    testImplementation("junit:junit:4.13.2")
}
