import java.security.MessageDigest

plugins {
    id("com.android.library") version "8.10.1"
    kotlin("android") version "2.2.21"
}

val sdkDirectory = providers.gradleProperty("quenderin.remoteCryptoDir").orNull?.let { file(it) }
    ?: throw GradleException("The real remote crypto module requires quenderin.remoteCryptoDir")
val verifier = rootProject.file("../native/remote-crypto/tools/native_sdk.py")
val verification = providers.exec {
    commandLine("python3", verifier.absolutePath, "verify", "--platform", "android", "--sdk", sdkDirectory.absolutePath)
}.result.get()
require(verification.exitValue == 0) { "Remote crypto SDK provenance verification failed" }

android {
    namespace = "ai.quenderin.remote.crypto"
    compileSdk = 36
    defaultConfig {
        minSdk = 28
        ndk { abiFilters += listOf("arm64-v8a") }
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    // Expose the generated source root in Android's model. Register the binding
    // directly with the external Kotlin compiler tasks below as well.
    sourceSets["main"].java.srcDir(sdkDirectory.resolve("kotlin"))
    sourceSets["main"].jniLibs.srcDir(sdkDirectory.resolve("jniLibs"))
    packaging.jniLibs.keepDebugSymbols += setOf("**/libquenderin_remote_crypto.so", "**/libjnidispatch.so")
}

// Check the actual compiler inputs, so lost source registration fails clearly
// before unresolved UniFFI symbols rather than only checking the SDK's files.
tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
    if (name == "compileDebugKotlin" || name == "compileReleaseKotlin") {
        val generatedBinding = sdkDirectory.resolve("kotlin/ai/quenderin/remote/crypto/quenderin_remote_crypto.kt")
        source(generatedBinding)
        doFirst {
            val generated = generatedBinding.canonicalFile
            val compilerSources = sources.asFileTree.files
            require(compilerSources.any { it.canonicalFile == generated }) {
                "Generated UniFFI binding is absent from $path compiler inputs: expected=$generated, exists=${generated.isFile}, sourceCount=${compilerSources.size}"
            }
        }
    }
}

// Pin the Android AAR, then verify the actual Gradle-resolved file before use.
// A host JAR has no Android libjnidispatch and cannot satisfy this dependency.
configurations.configureEach {
    incoming.afterResolve {
        resolvedConfiguration.resolvedArtifacts.filter { it.moduleVersion.id.group == "net.java.dev.jna" && it.name == "jna" }.forEach { artifact ->
            require(artifact.moduleVersion.id.version == "5.19.1" && artifact.extension == "aar") { "JNA must be the pinned Android AAR" }
            val sha = MessageDigest.getInstance("SHA-1").digest(artifact.file.readBytes()).joinToString("") { "%02x".format(it) }
            require(artifact.file.length() == 525093L && sha == "af25a9b1e286a62e2786388671c703b9a1f75a65") { "Android JNA AAR checksum differs" }
        }
    }
}

dependencies {
    implementation(project(":quenderin-core"))
    api("net.java.dev.jna:jna:5.19.1@aar")
}
