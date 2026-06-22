plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

// NOTE: Release signing is configured locally via android/key.properties and a
// keystore, which are intentionally excluded from this public source release.
// Provide your own key.properties + signingConfig to produce a signed release.

val defaultAbiFilters = listOf("armeabi-v7a", "arm64-v8a", "x86_64")
val flutterTargetAbiFilters = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)

val requestedAbiFilters = run {
    val explicit = (project.findProperty("retropalAbiFilters") as? String)
        ?.split(',', ';', ' ')
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }

    if (!explicit.isNullOrEmpty()) {
        explicit
    } else {
        val targetPlatformAbis = listOfNotNull(
            project.findProperty("retropalTargetPlatform") as? String,
            project.findProperty("target-platform") as? String,
        )
            .flatMap { it.split(',', ';', ' ') }
            .mapNotNull { flutterTargetAbiFilters[it.trim()] }
            .distinct()

        if (!targetPlatformAbis.isNullOrEmpty()) targetPlatformAbis else defaultAbiFilters
    }
}
val excludedAbiPackagingPatterns = defaultAbiFilters
    .filterNot { it in requestedAbiFilters.toSet() }
    .flatMap { abi -> listOf("lib/$abi/**", "**/$abi/**") }
// Only apply ABI exclusions when explicitly building a single-ABI APK
// (e.g. `flutter run -P retropalAbiFilters=armeabi-v7a`).
// When building an AAB for Play Store, all ABIs must be included so that
// Google Play can generate correct per-ABI splits — otherwise 32-bit TV
// devices receive an APK without libflutter.so and crash on launch.
val shouldExcludeAbis = (project.findProperty("retropalAbiFilters") as? String)
    ?.isNotBlank() == true
val requestedLibcxxPickFirsts = requestedAbiFilters
    .flatMap { abi -> listOf("lib/$abi/libc++_shared.so", "**/$abi/libc++_shared.so") }

android {
    namespace = "com.yourmateapps.retropal"
    compileSdk = flutter.compileSdkVersion
    // NDK r28+ is recommended for 16 KB page size, but we can force alignment on current
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    packaging {
        jniLibs {
            // Tells Gradle not to attempt stripping your pre-compiled libretro cores
            keepDebugSymbols.add("**/lib*_libretro_android.so")
            keepDebugSymbols.add("**/libyage_core.so")
            keepDebugSymbols.add("**/libsqlite3.so")

            // Note: If you only want to protect specific cores, you can use:
            // keepDebugSymbols.add("**/libmednafen_pce_fast_libretro_android.so")
            // keepDebugSymbols.add("**/libmupen64plus_next_gles3_libretro_android.so")
        }
    }

    defaultConfig {
        applicationId = "com.yourmateapps.retropal"
        minSdk = 24  // Android 7.0+ for better performance
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Support phones (arm64), older phones/TVs (armv7), and TV boxes
            // (x86_64) by default. For low-storage Android TV installs, pass a
            // single ABI through Flutter's Gradle project args:
            // `flutter run -P retropalTargetPlatform=android-arm`
            // or `flutter run -P retropalAbiFilters=armeabi-v7a`.
            // `flutter build apk --target-platform android-arm` is also mapped.
            abiFilters += requestedAbiFilters
        }

        // Build libyage_core.so from source for all ABIs automatically
        externalNativeBuild {
            cmake {
                // 16 KB page size support is configured in native/CMakeLists.txt
                // via target_link_options so the flag is applied at link time.
                arguments(
                    "-DANDROID_STL=none",
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    "-DANDROID_LD=lld"
                )
            }
        }
    }

    // Point to the native CMakeLists.txt
    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Release signing config is provided locally (see note at top).
        }
    }

    packaging {
        jniLibs {
            // Multiple dependencies may contribute this runtime; keep one copy
            // for the requested ABI only so non-target ABI runtimes do not
            // sneak back into low-storage TV APKs.
            pickFirsts += requestedLibcxxPickFirsts
            // Keep .so entries uncompressed/aligned in APK for modern Android
            // loader expectations (including 16 KB page-size capable mappings).
            useLegacyPackaging = false
            // Preserve bundled core binaries exactly as produced by the core
            // build script (avoid post-processing strip changes at packaging).
            keepDebugSymbols += setOf("**/*.so")
            // Only exclude non-target ABI libraries when explicitly building a
            // single-ABI APK. For AAB builds, keep all ABIs so Play Store can
            // correctly generate per-device splits with libflutter.so included.
            if (shouldExcludeAbis) {
                excludes += excludedAbiPackagingPatterns
            }
        }
    }
}

flutter {
    source = "../.."
}

// Force patched versions of GMS libraries to fix NPE crashes.
// play-services-auth:21.2.0 — fixes SignInHubActivity NPE on older devices.
configurations.all {
    resolutionStrategy {
        force("com.google.android.gms:play-services-auth:21.2.0")
    }
}
