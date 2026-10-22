import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The Rust core is built through cargo-ndk into `src/main/jniLibs/<abi>/`.
// `-PrbwaCargoProfile=debug` keeps dev builds fast (no LTO); release uses the
// workspace's size-optimized profile.
val rbwaCargoProfile: String =
    (project.findProperty("rbwaCargoProfile") as String?) ?: "release"
val rbwaRustDir: File = rootProject.projectDir.parentFile.resolve("rust")
val rbwaJniLibsDir: File = projectDir.resolve("src/main/jniLibs")

android {
    namespace = "work.csywxk.icefish_zhiyue"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "work.csywxk.icefish_zhiyue"
        // Android 8.0 -- the floor for modern SAF and 16KB-page capable devices.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // arm64 only: ort-sys ships ONNX Runtime prebuilts for
            // aarch64-linux-android (NNAPI) but NOT x86_64-linux-android, and
            // the OCR engine needs ORT. A 64-bit ARM device or an arm64
            // emulator image is required (see docs/ANDROID_V1_PLAN.md §0.3).
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            // Release signing is wired by scripts/build_android.sh when
            // android/key.properties exists; debug keys keep a fresh checkout
            // able to run `flutter run --release`.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Do not compress ONNX models inside the APK: the first-run installer
    // streams them out of assets, and deflate only adds CPU time.
    androidResources {
        noCompress += "onnx"
    }

    packaging {
        jniLibs {
            // 16KB page alignment (Android 15+): native libs must stay
            // uncompressed and page-aligned in the APK.
            useLegacyPackaging = false
        }
    }

}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// ---------------------------------------------------------------------------
// Rust core (cargo-ndk)
// ---------------------------------------------------------------------------

val cargoNdkBuild by tasks.registering(Exec::class) {
    group = "build"
    description = "Cross-compiles librbwa_core.so for Android ABIs with cargo-ndk."
    workingDir = rbwaRustDir
    // `cargo ndk` writes directly into the jniLibs tree.
    val args = mutableListOf(
        "cargo", "ndk",
        "-t", "arm64-v8a",
        "-o", rbwaJniLibsDir.absolutePath,
        "build",
    )
    if (rbwaCargoProfile == "release") args += "--release"
    commandLine(args)

    // Only rebuild when the Rust sources / manifest change.
    inputs.dir(rbwaRustDir.resolve("src"))
    inputs.file(rbwaRustDir.resolve("Cargo.toml"))
    outputs.dir(rbwaJniLibsDir)

    doFirst {
        logger.lifecycle("cargo-ndk: building librbwa_core (${rbwaCargoProfile})")
    }

    // cargo-ndk copies every cdylib in the dependency graph, which includes
    // pdfium-render's internal artifact. Only our own library belongs in the
    // APK; drop the rest so the package does not carry dead code.
    doLast {
        rbwaJniLibsDir.walkTopDown()
            .filter { it.isFile && it.name.startsWith("libpdfium_render-") }
            .forEach { it.delete() }
    }
}

/**
 * ORT is linked statically, but its C++ runtime still comes from the NDK.
 * Copy the matching libc++_shared.so next to our own libraries so the APK
 * carries exactly one copy per ABI.
 */
val copyCppShared by tasks.registering {
    group = "build"
    description = "Copies libc++_shared.so from the NDK into jniLibs."
    dependsOn(cargoNdkBuild)
    doLast {
        // AGP 9 deprecates `android.ndkDirectory`; resolve the NDK directly
        // from the environment / local.properties instead.
        val ndkDir: File = System.getenv("ANDROID_NDK_HOME")?.let { file(it) }
            ?: System.getenv("ANDROID_NDK_ROOT")?.let { file(it) }
            ?: run {
                val props = Properties()
                val localProps = rootProject.file("local.properties")
                if (localProps.isFile) {
                    localProps.inputStream().use { props.load(it) }
                }
                val sdk = props.getProperty("sdk.dir")
                    ?: System.getenv("ANDROID_HOME")
                    ?: System.getenv("ANDROID_SDK_ROOT")
                    ?: error("Android SDK not found: set ANDROID_HOME or sdk.dir")
                val ndkRoot = File(sdk, "ndk")
                ndkRoot.listFiles()?.maxByOrNull { it.name }
                    ?: error("No NDK installed under ${ndkRoot.absolutePath}")
            }
        val osName = System.getProperty("os.name").lowercase()
        val hostTag = when {
            osName.contains("linux") -> "linux-x86_64"
            osName.contains("mac") -> "darwin-x86_64"
            else -> "windows-x86_64"
        }
        for ((abi, triple) in listOf("arm64-v8a" to "aarch64-linux-android")) {
            val src = ndkDir.resolve(
                "toolchains/llvm/prebuilt/$hostTag/sysroot/usr/lib/$triple/libc++_shared.so",
            )
            if (src.isFile) {
                src.copyTo(rbwaJniLibsDir.resolve(abi).resolve("libc++_shared.so"), overwrite = true)
            } else {
                logger.warn("libc++_shared.so not found for $abi ($src)")
            }
        }
    }
}

tasks.named("preBuild") {
    dependsOn(copyCppShared)
}

flutter {
    source = "../.."
}
