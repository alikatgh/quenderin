// Pure-Kotlin/JVM core module — the portable "brain", with no Android framework
// dependencies, so it compiles fast and unit-tests on the JVM. The Android `:app`
// module (Jetpack Compose UI + the JNI LlamaEngine) depends on this.
plugins {
    kotlin("jvm") version "2.0.21"
}

repositories { mavenCentral() }

dependencies {
    testImplementation(kotlin("test"))
}

kotlin { jvmToolchain(17) }

tasks.test { useJUnitPlatform() }
