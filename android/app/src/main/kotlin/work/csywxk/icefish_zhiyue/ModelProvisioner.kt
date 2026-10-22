package work.csywxk.icefish_zhiyue

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import org.json.JSONObject

/**
 * Installs the OCR models shipped in `assets/models/` into
 * `filesDir/models/` on first launch (and when the bundled manifest version
 * changes).
 *
 * Layout inside the APK (produced by `scripts/stage_android_models.sh`):
 *
 * ```
 * assets/models/manifest.json          version + per-file sha256 + bytes
 * assets/models/cls.onnx
 * assets/models/ppocr_keys_v1.txt
 * assets/models/high_precision/{det,rec}.onnx
 * assets/models/fast/{det,rec}.onnx
 * ```
 *
 * The destination mirrors what the Rust core already resolves as its dev
 * fallback (`{app_data_dir}/models`), so no Rust-side Android special case is
 * needed beyond skipping the `current_exe()` probe.
 *
 * Copies are streamed (8 KiB buffer), hashed after writing, written to a
 * `.tmp` sibling and renamed only after the hash matches. An interrupted run
 * therefore can never leave a corrupt model in place; the next launch retries.
 */
class ModelProvisioner(
    private val messenger: BinaryMessenger,
    private val context: Context,
) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        private const val CHANNEL = "rbwa/models"
        private const val MANIFEST = "manifest.json"
        private const val INSTALLED_MARKER = ".manifest.json"
        private const val BUFFER_SIZE = 8 * 1024
        /** Headroom for the temporary copy plus SQLite/WAL while installing. */
        private const val REQUIRED_FREE_BYTES = 350L * 1024 * 1024
        /** Progress messages are throttled to keep the platform channel quiet. */
        private const val PROGRESS_STEP_BYTES = 1L * 1024 * 1024
    }

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureInstalled" -> ensureInstalled(call, result)
                "status" -> result.success(statusMap())
                else -> result.notImplemented()
            }
        }
    }

    private fun modelsDir(): File = File(context.filesDir, "models")

    private fun statusMap(): Map<String, Any?> {
        val dir = modelsDir()
        val marker = File(dir, INSTALLED_MARKER)
        return mapOf(
            "installed" to (marker.isFile && hasAllModes(dir)),
            "path" to dir.absolutePath,
            "version" to if (marker.isFile) readJson(marker)?.optString("version") ?: "" else "",
            "bytes" to dirSize(dir),
        )
    }

    /** Both model sets are only "installed" when every expected file exists. */
    private fun hasAllModes(dir: File): Boolean =
        File(dir, "cls.onnx").isFile &&
            File(dir, "ppocr_keys_v1.txt").isFile &&
            File(dir, "high_precision/det.onnx").isFile &&
            File(dir, "high_precision/rec.onnx").isFile &&
            File(dir, "fast/det.onnx").isFile &&
            File(dir, "fast/rec.onnx").isFile

    private fun ensureInstalled(call: MethodCall, result: MethodChannel.Result) {
        val force = call.argument<Boolean>("force") ?: false
        worker.execute {
            try {
                val manifest = readAssetJson(MANIFEST)
                    ?: throw IllegalStateException(
                        "assets/models/manifest.json 缺失；先运行 scripts/stage_android_models.sh",
                    )
                val version = manifest.optString("version")
                val dir = modelsDir()
                val marker = File(dir, INSTALLED_MARKER)

                val upToDate = !force &&
                    marker.isFile &&
                    readJson(marker)?.optString("version") == version &&
                    hasAllModes(dir)

                if (!upToDate) {
                    dir.mkdirs()
                    val usable = dir.usableSpace
                    if (usable in 1 until REQUIRED_FREE_BYTES) {
                        throw IllegalStateException(
                            "可用空间不足：需要约 ${REQUIRED_FREE_BYTES / 1024 / 1024} MB，" +
                                "当前 ${usable / 1024 / 1024} MB",
                        )
                    }
                    install(manifest, dir) { copied, total, name ->
                        mainHandler.post {
                            channel.invokeMethod(
                                "onProgress",
                                mapOf("done" to copied, "total" to total, "file" to name),
                            )
                        }
                    }
                    // Marker last: a crash before this line simply retries.
                    marker.writeText(manifest.toString())
                }

                mainHandler.post { result.success(statusMap()) }
            } catch (e: Exception) {
                mainHandler.post { result.error("install_failed", e.message, null) }
            }
        }
    }

    private fun install(
        manifest: JSONObject,
        dir: File,
        onProgress: (Long, Long, String) -> Unit,
    ) {
        val files = manifest.optJSONArray("files")
            ?: throw IllegalStateException("manifest.json 缺少 files")
        var totalBytes = 0L
        val entries = ArrayList<Triple<String, String, Long>>()
        for (i in 0 until files.length()) {
            val f = files.getJSONObject(i)
            val path = f.getString("path")
            val sha = f.getString("sha256")
            val bytes = f.optLong("bytes").let { if (it > 0) it else assetSize(path) }
            entries.add(Triple(path, sha, bytes))
            totalBytes += bytes.coerceAtLeast(0)
        }

        var copied = 0L
        var lastReported = 0L
        fun report(name: String, force: Boolean = false) {
            if (force || copied - lastReported >= PROGRESS_STEP_BYTES) {
                lastReported = copied
                onProgress(copied, totalBytes, name)
            }
        }

        for ((path, expectedSha, bytes) in entries) {
            val dest = File(dir, path)
            if (dest.isFile && bytes > 0 && dest.length() == bytes && sha256(dest) == expectedSha) {
                copied += bytes
                report(path, force = true)
                continue
            }
            dest.parentFile?.mkdirs()
            val tmp = File(dest.parentFile, "${dest.name}.tmp")
            var written = 0L
            context.assets.open("models/$path").use { input ->
                if (tmp.exists()) tmp.delete()
                FileOutputStream(tmp).use { output ->
                    val buffer = ByteArray(BUFFER_SIZE)
                    while (true) {
                        val n = input.read(buffer)
                        if (n <= 0) break
                        output.write(buffer, 0, n)
                        written += n
                        copied += n
                        report(path)
                    }
                    output.fd.sync()
                }
            }
            if (written == 0L) {
                tmp.delete()
                throw IllegalStateException("$path 为空")
            }
            val actual = sha256(tmp)
            if (actual != expectedSha) {
                tmp.delete()
                throw IllegalStateException("$path 校验失败（期望 $expectedSha，实际 $actual）")
            }
            if (!tmp.renameTo(dest)) {
                tmp.copyTo(dest, overwrite = true)
                tmp.delete()
            }
            report(path, force = true)
        }
    }

    /** Uncompressed assets expose an FD; compressed ones have no known size. */
    private fun assetSize(path: String): Long = try {
        context.assets.openFd("models/$path").use { it.length }
    } catch (_: Exception) {
        0L
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(BUFFER_SIZE)
            while (true) {
                val n = input.read(buffer)
                if (n <= 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun readAssetJson(path: String): JSONObject? = try {
        context.assets.open("models/$path").bufferedReader().use {
            JSONObject(it.readText())
        }
    } catch (_: Exception) {
        null
    }

    private fun readJson(file: File): JSONObject? = try {
        JSONObject(file.readText())
    } catch (_: Exception) {
        null
    }

    private fun dirSize(dir: File): Long {
        if (!dir.exists()) return 0
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }
}
