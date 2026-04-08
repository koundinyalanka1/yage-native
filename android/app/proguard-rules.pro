# Flutter specific rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Keep native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# YAGE specific
-keep class com.yourmateapps.retropal.** { *; }

# Google Play Core (referenced by Flutter's deferred components support)
-dontwarn com.google.android.play.core.splitcompat.**
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**

# ── Google Sign-In / Play Services Auth ───────────────────────────────
# R8 can strip Parcelable / internal types used when starting
# SignInHubActivity, causing NPE (getClass on null) in release builds.
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

-keep class com.google.android.gms.common.** { *; }
-keep class com.google.android.gms.auth.** { *; }
-keep class com.google.android.gms.auth.api.signin.** { *; }
-keep class com.google.android.gms.auth.api.signin.internal.** { *; }
-dontwarn com.google.android.gms.**

-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
