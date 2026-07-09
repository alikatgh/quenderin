// The Android app: Jetpack Compose UI over the pure-Kotlin :quenderin-core brain.
// Boots on MockInferenceEngine so it runs the moment you open it in Android Studio;
// the JNI llama.cpp build is opt-in (uncomment externalNativeBuild + ndk once you've
// added llama.cpp — see android/INTEGRATION.md). Same shape as the iOS app target.
//
// NOTE: requires the Android SDK + AGP (Android Studio / Gradle) to build — it is NOT
// compiled by the headless kotlinc check that proves :quenderin-core.
import java.util.Properties

plugins {
    id("com.android.application") version "8.5.2"
    kotlin("android") version "2.0.21"
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21"
}

// Release signing credentials come from a GITIGNORED keystore.properties at the repo root — never git.
// Absent (CI, contributors, debug builds) → release builds unsigned but STILL build. See docs/RELEASE.md.
//   keystore.properties:  storeFile=/abs/path/upload.jks  storePassword=…  keyAlias=…  keyPassword=…
val keystorePropertiesFile = rootProject.file("keystore.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) keystorePropertiesFile.inputStream().use { load(it) }
}
val hasReleaseSigning = keystoreProperties.containsKey("storeFile")

// Auto-detect a llama.cpp checkout at android/jni/llama.cpp (git submodule or symlink).
// Present  → the JNI bridge is compiled and LlamaEngine does real on-device inference.
// Absent   → the app builds clean and runs on MockInferenceEngine.
// This mirrors iOS Package.swift's xcframework auto-detection — same "clean by default,
// real when the native checkout is present" contract. Add it with:
//   git submodule add https://github.com/ggml-org/llama.cpp android/jni/llama.cpp
val nativeLlama = file("../jni/llama.cpp").exists()

android {
    namespace = "ai.quenderin.app"
    compileSdk = 35

    // Vulkan is ON by default (2026-07-09): Adreno devices get full GPU offload via
    // GpuOffloadPlanner; Mali/Xclipse/unknown stay on CPU until forceGpu. Opt OUT with
    // -Pquenderin.vulkan=false for a CPU-only .so (smaller / more portable for emulators).
    val enableVulkan = project.findProperty("quenderin.vulkan")?.toString() != "false"

    defaultConfig {
        applicationId = "ai.quenderin.app"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        
        buildConfigField("boolean", "QUENDERIN_VULKAN", if (enableVulkan) "true" else "false")

        if (nativeLlama) {
            ndk { abiFilters += listOf("arm64-v8a") }   // add "x86_64" for x86 emulators
            externalNativeBuild {
                cmake {
                    if (enableVulkan) {
                        arguments += "-DQUENDERIN_VULKAN=ON"
                    }
                }
            }
        }
    }

    if (nativeLlama) {
        ndkVersion = "26.3.11579264"
        externalNativeBuild {
            cmake {
                path = file("../jni/CMakeLists.txt")
                version = "3.22.1"
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // Extract .so files to nativeLibraryDir instead of mmapping them from inside the APK:
            // ggml's CPU-variant runtime pick (ggml_backend_load_all_from_path) enumerates that
            // directory with a filesystem scan, which sees nothing when the libs only exist as APK
            // entries. Costs some disk (no shared APK mmap) — the price of the DOTPROD/I8MM kernels.
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Sign only when credentials are present; otherwise produce an unsigned release that still
            // builds (so CI / contributors are never blocked on a keystore they don't have).
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
            // R8 shrinking is OFF by default: it's an APK-size optimization, not required to ship, and it
            // can't be verified headlessly here. Flip to `true` and run `:app:bundleRelease` on a machine
            // with the SDK to test — proguard-rules.pro ALREADY carries the JNI keeps R8 needs (the C++
            // resolves cancelRequested / onToken / the native methods by name, so they must not be renamed).
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

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
    // Background, resumable model downloads (ModelDownloadWorker + WorkManagerModelDownloader).
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("androidx.core:core-ktx:1.13.1") // NotificationCompat for the download notification
    implementation("androidx.documentfile:documentfile:1.0.1") // SAF workspace fs.* (DocWorkspace.kt)
    debugImplementation("androidx.compose.ui:ui-tooling")
}
