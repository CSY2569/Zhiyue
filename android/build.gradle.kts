allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// Flutter 3.47 requires Android API 36 (its plugins depend on
// flutter_plugin_android_lifecycle, which demands compileSdk 36). Older
// third-party plugins pinned to 34 (file_picker 8.x) would otherwise fail
// `checkDebugAarMetadata`. Raising the library compileSdk is safe: it only
// exposes newer APIs at compile time and does not change runtime behavior
// (targetSdk/minSdk stay untouched).
subprojects {
    // Must run AFTER the plugin's own `android {}` block (file_picker 8.x
    // hard-codes compileSdk 34 there, which would overwrite an earlier
    // assignment).
    afterEvaluate {
        extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.let { ext ->
            val current = ext.compileSdk ?: 0
            if (current < 36) ext.compileSdk = 36
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
