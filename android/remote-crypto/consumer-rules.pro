# Core performs one fixed-class lookup; preserve only that provider entry point.
-keep class ai.quenderin.remote.crypto.NativeRemoteHarnessCryptoBackend { public <init>(); }
# Generated UniFFI/JNA direct mappings resolve native method names and fields.
-keep class ai.quenderin.remote.crypto.UniffiLib { *; }
-keep class ai.quenderin.remote.crypto.IntegrityCheckingUniffiLib { *; }
-keep class ai.quenderin.remote.crypto.** extends com.sun.jna.Structure { *; }
-keep class com.sun.jna.** { *; }
-dontwarn java.awt.**
