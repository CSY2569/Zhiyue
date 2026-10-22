package work.csywxk.icefish_zhiyue

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Hosts the Flutter UI and wires the platform channels the Rust core cannot
 * reach from inside the Flutter engine:
 *
 *  - `rbwa/models` — copies the bundled OCR models out of assets on first run
 *    (and after a model upgrade) into the app-private files dir.
 *  - `rbwa/system` — exposes paths (native lib dir) and memory-pressure hints.
 *  - `rbwa/display` — dynamic refresh-rate hints (30-120 Hz).
 */
class MainActivity : FlutterActivity() {
    private var systemBridge: SystemBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        ModelProvisioner(messenger, applicationContext).register()
        systemBridge = SystemBridge(messenger, applicationContext, this).also { it.register() }
        DisplayRefreshBridge(this, messenger).register()
        // Files delivered with the launch intent (cold start).
        SystemBridge.captureIntent(this, intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // Files shared / opened while the app is already running.
        SystemBridge.captureIntent(this, intent)
    }

    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        systemBridge?.onTrimMemory(level)
    }
}
