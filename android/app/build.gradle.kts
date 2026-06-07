// The Android app: Jetpack Compose UI over the pure-Kotlin :quenderin-core brain.
// Boots on MockInferenceEngine so it runs the moment you open it in Android Studio;
// the JNI llama.cpp build is opt-in (uncomment externalNativeBuild + ndk once you've
// added llama.cpp — see android/INTEGRATION.md). Same shape as the iOS app target.
//
// NOTE: requires the Android SDK + AGP (Android Studio / Gradle) to build — it is NOT
// compiled by the headless kotlinc check that proves :quenderin-core.
plugins {
    id("com.android.application") version "8.5.2"
    kotlin("android") version "2.0.21"
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21"
}

android {
    namespace = "ai.quenderin.app"
    compileSdk = 35

    defaultConfig {
        applicationId = "ai.quenderin.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"

        // --- On-device inference (opt-in). Uncomment after adding llama.cpp under
        //     android/jni/llama.cpp (git submodule) — see android/INTEGRATION.md.
        //     Until then the app builds clean and runs on MockInferenceEngine.
        // ndk { abiFilters += listOf("arm64-v8a") }   // add "x86_64" for the emulator
    }

    // externalNativeBuild {
    //     cmake {
    //         path = file("../jni/CMakeLists.txt")
    //         version = "3.22.1"
    //     }
    // }

    buildFeatures { compose = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    sourceSets["main"].kotlin.srcDir("src/main/kotlin")
}

dependencies {
    implementation(project(":quenderin-core"))

    val composeBom = platform("androidx.compose:compose-bom:2024.09.03")
    implementation(composeBom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
