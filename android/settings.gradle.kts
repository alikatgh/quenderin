pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "quenderin-android"

// The portable pure-Kotlin/JVM brain (verified headlessly via kotlinc + CoreVerify).
include(":quenderin-core")

// The Jetpack Compose app over the brain. Boots on the mock engine; the JNI llama.cpp
// build is opt-in (see android/INTEGRATION.md). Needs the Android SDK + AGP to build.
include(":app")

// No generated bindings/JNA in the portable JVM core. Explicit native artifacts
// add the real Android provider; absent artifacts expose an unavailable backend.
if (providers.gradleProperty("quenderin.remoteCryptoDir").isPresent) {
    include(":remote-crypto")
}
