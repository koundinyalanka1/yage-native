import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}



android {
    namespace = "com.yourmateapps.retropal"
    compileSdk = flutter.compileSdkVersion
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
            keepDebugSymbols.add("**/lib*_libretro_android.so")
            keepDebugSymbols.add("**/libyage_core.so")
            keepDebugSymbols.add("**/libsqlite3.so")
        }
    }

    

    defaultConfig {
        applicationId = "com.yourmateapps.retropal"
        minSdk = 24  
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments(
                    "-DANDROID_STL=none",
                    "-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON",
                    "-DANDROID_LD=lld"
                )
            }
        }
    }
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
            
        }
    }

    packaging {
        jniLibs {
            pickFirsts += setOf("**/libc++_shared.so")
            useLegacyPackaging = false
            keepDebugSymbols += setOf("**/*.so")
        }
    }
}

flutter {
    source = "../.."
}
