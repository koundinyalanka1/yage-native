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
-keep class com.google.android.gms.auth.api.credentials.** { *; }
-dontwarn com.google.android.gms.**

# Keep all Parcelable implementations and their CREATOR fields intact.
# SignInHubActivity deserializes SignInConfiguration from Intent extras;
# if R8 removes the CREATOR or renames the class, deserialization returns
# null → NPE.
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}
-keep class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator *;
}
-keepnames class * implements android.os.Parcelable
-keepnames class * implements java.io.Serializable

# Keep Google Identity / Credential Manager classes (new sign-in path)
-keep class com.google.android.libraries.identity.** { *; }
-keep class com.google.android.gms.fido.** { *; }
-keep class androidx.credentials.** { *; }

# ── Google Play Billing ───────────────────────────────────────────────
# ProxyBillingActivity deserializes a PendingIntent from its launching
# Intent extras. R8 must not strip or rename any billing client classes
# that implement Parcelable, or the deserialization yields null → NPE.
-keep class com.android.billingclient.api.** { *; }
-keep class com.android.vending.billing.** { *; }
-dontwarn com.android.billingclient.**
-dontwarn com.android.vending.**
