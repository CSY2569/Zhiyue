package io.github.csy2569.zhiyue

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Parcelable
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Platform facts the Rust core and the UI need on Android:
 *
 *  - `nativeLibraryDir`: where `libpdfium.so` lives. `std::env::current_exe()`
 *    returns the zygote's `app_process` on Android, so the Rust pdfium loader
 *    cannot find its library by walking up from the executable; the Dart layer
 *    passes this path down instead.
 *  - `availableProcessors` / `memoryClass`: used to size the OCR thread pool.
 *  - `onTrimMemory`: forwarded to Dart so page bitmap caches can be dropped
 *    before the OS kills the process.
 *  - `setKeepScreenOn`: keeps the display awake while reading.
 *  - `takeIncomingFiles`: files delivered by ACTION_VIEW / ACTION_SEND,
 *    copied into the app cache dir by [captureIntent].
 */
class SystemBridge(
    private val messenger: BinaryMessenger,
    private val context: Context,
    private val activity: Activity?,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    companion object {
        private const val CHANNEL = "rbwa/system"

        /** Files handed to us before Dart was ready (cold start). */
        private val pendingIncoming = mutableListOf<String>()

        /** Records the paths carried by [intent], if any. */
        fun captureIntent(context: Context, intent: Intent?) {
            if (intent == null) return
            val uri: Uri? = when (intent.action) {
                Intent.ACTION_VIEW -> intent.data
                Intent.ACTION_SEND -> {
                    @Suppress("DEPRECATION")
                    val extra: Parcelable? =
                        intent.getParcelableExtra(Intent.EXTRA_STREAM)
                    extra as? Uri
                }
                else -> null
            }
            if (uri == null) return
            copyToCache(context, uri)?.let { pendingIncoming.add(it) }
        }

        /**
         * Streams a content:// URI into `cacheDir/incoming/`. The reader
         * imports from a real file path; content URIs are not seekable files
         * and the permission grant does not outlive the activity.
         */
        private fun copyToCache(context: Context, uri: Uri): String? = try {
            val dir = File(context.cacheDir, "incoming").apply { mkdirs() }
            val name = displayName(context, uri) ?: "incoming_${System.currentTimeMillis()}"
            val dest = File(dir, name)
            context.contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            }
            if (dest.isFile && dest.length() > 0) dest.absolutePath else null
        } catch (_: Throwable) {
            null
        }

        private fun displayName(context: Context, uri: Uri): String? = try {
            context.contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (_: Throwable) {
            null
        }
    }

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(infoMap())
                "setKeepScreenOn" -> {
                    val on = call.argument<Boolean>("on") ?: false
                    if (on) {
                        activity?.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "takeIncomingFiles" -> {
                    val files = pendingIncoming.toList()
                    pendingIncoming.clear()
                    result.success(files)
                }
                "setSystemUiMode" -> {
                    val immersive = call.argument<Boolean>("immersive") ?: false
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun infoMap(): Map<String, Any?> {
        val activityManager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val memoryInfo = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(memoryInfo)
        return mapOf(
            "nativeLibraryDir" to context.applicationInfo.nativeLibraryDir,
            "filesDir" to context.filesDir.absolutePath,
            "cacheDir" to context.cacheDir.absolutePath,
            "availableProcessors" to Runtime.getRuntime().availableProcessors(),
            "isLowRamDevice" to (activityManager?.isLowRamDevice ?: false),
            "totalRamBytes" to memoryInfo.totalMem,
            "availRamBytes" to memoryInfo.availMem,
            "lowMemory" to memoryInfo.lowMemory,
        )
    }

    /** Called by the Flutter engine's host activity on `onTrimMemory`. */
    fun onTrimMemory(level: Int) {
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            channel.invokeMethod("onTrimMemory", mapOf("level" to level))
        }
    }
}
