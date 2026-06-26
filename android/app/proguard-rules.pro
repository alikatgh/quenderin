# R8 / ProGuard rules for the release build (referenced from app/build.gradle.kts).
#
# Minify is OFF by default (see build.gradle.kts). These rules exist so that the moment you flip
# `isMinifyEnabled = true` to shrink the APK, the JNI bridge keeps working. WITHOUT them, R8 would
# rename or strip members that the native code (android/jni/llama_jni.cpp) resolves BY NAME at
# runtime — and the first call into llama.cpp would crash with a NoSuchMethod/Field error.

# --- JNI surface (android/jni/llama_jni.cpp) ---

# Native method declarations must keep their names so the dynamic linker can bind them.
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# The native decode loop polls this field via GetFieldID(thiz, "cancelRequested", "Z") to honor a
# model-switch/cancel mid-generation (audit M3). Keep its exact name.
-keepclassmembers class ai.quenderin.core.LlamaEngine {
    private boolean cancelRequested;
}

# The streaming bridge calls TokenSink.onToken(String) via GetMethodID — keep the whole interface so
# the method name + descriptor survive shrinking.
-keep class ai.quenderin.core.LlamaEngine$TokenSink { *; }

# Jetpack Compose and AGP ship their own consumer ProGuard rules; the default
# proguard-android-optimize.txt covers the rest. Add app-specific keeps here if you later hit a
# reflection-based stripping issue in a release build.
