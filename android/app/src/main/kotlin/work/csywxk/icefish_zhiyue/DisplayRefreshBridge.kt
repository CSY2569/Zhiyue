package io.github.csy2569.zhiyue

import android.app.Activity
import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.view.Display
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Dynamic display refresh-rate hints (30-120 Hz).
 *
 * Flutter renders on its own `SurfaceView`; on Android 11+ the app can ask
 * the platform to switch that surface's frame rate without a display-mode
 * change (`Surface.setFrameRate`, which LTPO panels honour as a range). On
 * older releases the only knob is `WindowManager.LayoutParams
 * .preferredRefreshRate`, which triggers a discrete mode change -- usable but
 * potentially visible, so it is the fallback.
 *
 * The Dart [RefreshRateController] decides *when* to ask: the maximum
 * supported rate during scrolling / gestures, and a low idle rate when the
 * screen has been still for a while. This class only clamps the request to a
 * rate the display actually advertises and applies it.
 */
class DisplayRefreshBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val channel = MethodChannel(messenger, CHANNEL)

    companion object {
        private const val CHANNEL = "rbwa/display"
        private const val MIN_RATE = 24.0
    }

    fun register() {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "info" -> result.success(displayInfo())
                "setFrameRate" -> {
                    val fps = (call.argument<Number>("fps") ?: 0).toFloat()
                    result.success(applyFrameRate(fps))
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Current rate + every mode's refresh rate, so Dart can clamp requests. */
    private fun displayInfo(): Map<String, Any?> {
        val display = defaultDisplay()
        val rates = display
            ?.supportedModes
            ?.map { (it.refreshRate * 10).toInt() / 10.0 }
            ?.distinct()
            ?.sorted()
            ?: emptyList()
        return mapOf(
            "supportedRates" to rates,
            "currentRate" to ((display?.refreshRate ?: 0f).toDouble()),
            "apiLevel" to Build.VERSION.SDK_INT,
        )
    }

    private fun defaultDisplay(): Display? {
        val dm = activity.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
        return dm?.getDisplay(Display.DEFAULT_DISPLAY)
    }

    /**
     * Applies [requested] (clamped to the nearest supported mode) and returns
     * the rate actually requested, or -1 when no path is available.
     */
    private fun applyFrameRate(requested: Float): Double {
        if (requested <= 0f) return -1.0
        val target = nearestSupported(requested) ?: requested.toDouble()

        // Preferred path: per-surface frame-rate hint, no mode change.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val surface = findSurfaceView(activity.window.decorView)?.holder?.surface
            if (surface != null && surface.isValid) {
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        surface.setFrameRate(
                            target.toFloat(),
                            Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                            Surface.CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS,
                        )
                    } else {
                        // API 30: 2-arg form (the 3-arg strategy overload
                        // arrived in API 31).
                        surface.setFrameRate(
                            target.toFloat(),
                            Surface.FRAME_RATE_COMPATIBILITY_DEFAULT,
                        )
                    }
                    return target
                } catch (_: Throwable) {
                    // Some OEM surfaces reject the hint; fall through.
                }
            }
        }

        // Fallback (API 23+): pick the closest display mode. This can cause a
        // brief mode switch, so it is only used when setFrameRate failed.
        return try {
            val attrs = activity.window.attributes
            attrs.preferredRefreshRate = target.toFloat()
            activity.window.attributes = attrs
            target
        } catch (_: Throwable) {
            -1.0
        }
    }

    /** Nearest advertised refresh rate, tolerating fractional modes (59.94). */
    private fun nearestSupported(requested: Float): Double? {
        val rates = defaultDisplay()
            ?.supportedModes
            ?.map { it.refreshRate.toDouble() }
            ?.filter { it >= MIN_RATE }
            ?: return null
        if (rates.isEmpty()) return null
        return rates.minByOrNull { kotlin.math.abs(it - requested) }
    }

    /** Flutter's rendering surface lives somewhere under the decor view. */
    private fun findSurfaceView(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findSurfaceView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }
}
