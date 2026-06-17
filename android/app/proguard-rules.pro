# ─── IBITI Guardian ProGuard Rules ────────────────────────────────────────────
# These rules ensure reflection-heavy crypto/wallet libraries survive R8
# obfuscation in release builds.

# ── Flutter ──────────────────────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# ── Privy SDK ────────────────────────────────────────────────────────────────
# Privy uses reflection for OAuth redirect and embedded wallet RPC calls.
-keep class io.privy.** { *; }
-keepclassmembers class io.privy.** { *; }
-dontwarn io.privy.**

# ── Web3Dart / Wallet ────────────────────────────────────────────────────────
# web3dart uses JSON-RPC serialization that breaks under obfuscation.
-keep class org.web3j.** { *; }
-dontwarn org.web3j.**

# ── HTTP / OkHttp / Cronet ───────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn javax.annotation.**
-dontwarn org.chromium.net.**

# ── AndroidX Browser (Custom Tabs for Privy OAuth) ──────────────────────────
-keep class androidx.browser.** { *; }

# ── Kotlin Serialization ────────────────────────────────────────────────────
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses
-keepattributes EnclosingMethod

# ── General safety ──────────────────────────────────────────────────────────
# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep enums (used in chain registry, EPK state, etc.)
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# Keep Parcelable implementations
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# ── Suppress harmless warnings ──────────────────────────────────────────────
-dontwarn java.lang.invoke.StringConcatFactory
