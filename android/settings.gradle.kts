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

// Patched versions for vulnerable transitives of the Android Gradle Plugin classpath.
// These are build-time libraries (not packaged into the app). The pins are the versions
// that close the open high/critical advisories without moving AGP:
//   bcprov/bcpkix/bcutil 1.85 — name constraints, GOST CTR keystream, FrodoKEM timing channel
//   netty 4.1.139.Final — SNI routing bypass (fixed on the 4.1 line in 4.1.137.Final)
//   jdom2 2.0.6.1 — SAXBuilder XXE
//   protobuf-java 3.25.5 — nested-group parse denial of service
val securityPinnedClasspath = arrayOf(
    "org.bouncycastle:bcprov-jdk18on:1.85",
    "org.bouncycastle:bcpkix-jdk18on:1.85",
    "org.bouncycastle:bcutil-jdk18on:1.85",
    "io.netty:netty-common:4.1.139.Final",
    "io.netty:netty-buffer:4.1.139.Final",
    "io.netty:netty-codec:4.1.139.Final",
    "io.netty:netty-codec-http:4.1.139.Final",
    "io.netty:netty-codec-http2:4.1.139.Final",
    "io.netty:netty-codec-socks:4.1.139.Final",
    "io.netty:netty-handler:4.1.139.Final",
    "io.netty:netty-handler-proxy:4.1.139.Final",
    "io.netty:netty-resolver:4.1.139.Final",
    "io.netty:netty-transport:4.1.139.Final",
    "io.netty:netty-transport-native-unix-common:4.1.139.Final",
    "org.jdom:jdom2:2.0.6.1",
    "com.google.protobuf:protobuf-java:3.25.5",
    "com.google.protobuf:protobuf-java-util:3.25.5",
    "com.google.protobuf:protobuf-kotlin:3.25.5",
)

gradle.beforeProject {
    buildscript.configurations.configureEach {
        if (name == "classpath") {
            resolutionStrategy.force(*securityPinnedClasspath)
        }
    }
    configurations.configureEach {
        resolutionStrategy.force(*securityPinnedClasspath)
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
